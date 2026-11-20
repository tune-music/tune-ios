import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// Позиция трека отдельно от плеера: она меняется дважды в секунду, и перерисовывать
/// из-за неё нужно только полосу перемотки.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

enum RepeatMode: String {
    case off, all, one
}

/// Одно прослушивание трека для отчёта plays. Поля те же, что шлёт официальный клиент.
private struct Listen {
    let id = UUID().uuidString.lowercased()
    let track: Track
    let context: PlayContext
    let session: String?
    let added: String
    let started = API.now()
    var played: Double = 0
    var seek = false
    var pause = false

    init(track: Track, context: PlayContext, session: String?) {
        self.track = track
        self.context = context
        self.session = session
        added = "\(Int.random(in: 0..<10_000_000_000_000_000))-\(Int(Date().timeIntervalSince1970) + 1)"
    }

    func report(position: Double, first: Bool) -> [String: Any] {
        let length = track.duration
        // Почти до конца — значит до конца: так же округляет официальный клиент.
        func snap(_ value: Double) -> Double { abs(length - value) < 0.5 ? length : value }
        func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
        var play: [String: Any] = [
            "playId": id,
            "from": "tune-ios",
            "totalPlayedSeconds": first ? 0 : round3(snap(min(played, length))),
            "endPositionSeconds": first ? 0 : round3(snap(position)),
            "trackLengthSeconds": round3(length),
            "timestamp": API.now(),
            "context": context.kind,
            "contextItem": (context.item as Any?) ?? NSNull(),
            "addTracksToPlayerTime": added,
            "fromCache": false,
            "isRestored": false,
            "audioAuto": "none",
            "audioOutputName": "Динамик",
            "audioOutputType": "Speaker",
            "trackId": track.id,
            "seek": seek,
            "pause": pause,
            "isRepeated": false,
            "isLivePlayableIndex": session != nil,
            "startTimestamp": started,
        ]
        if let album = track.albumId { play["albumId"] = album }
        if let session {
            play["radioSessionId"] = session
            if let batch = track.batch { play["batchId"] = batch }
        }
        if !first { play["maxPlayerStage"] = "play" }
        return play
    }
}

/// Какой трек играет и играет ли он. Строки списков следят только за этим, а не за всем
/// плеером: буферизация, очередь и прочее их не перерисовывают.
@MainActor
final class NowPlaying: ObservableObject {
    @Published fileprivate(set) var id: String?
    @Published fileprivate(set) var playing = false
    /// Откуда играет очередь: radio, album, playlist, artist или various.
    @Published fileprivate(set) var kind = ""
    /// Что именно: номер альбома или плейлиста, а у волны — её настройки через запятую.
    @Published fileprivate(set) var item: String?
    /// Название источника: «Моя волна», имя плейлиста.
    @Published fileprivate(set) var name = ""

    /// Играет ли сейчас очередь из этого источника (пусть и на паузе).
    func from(_ kind: String, _ item: String) -> Bool {
        self.kind == kind && self.item == item
    }
}

@MainActor
final class Player: NSObject, ObservableObject {
    static let shared = Player()

    let now = NowPlaying()
    /// Последняя смена трека была назад по очереди: обложка выезжает с другой стороны.
    private(set) var movedBack = false
    private var bag = Set<AnyCancellable>()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var contextName = ""
    @Published var errorText: String?
    /// Таймер сна: когда музыка остановится сама.
    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepAfterTrack = false
    private var selectedVersion: TrackFiles.Version?
    @Published private(set) var audibleVersion: TrackFiles.Version?
    @Published private(set) var sound = SoundSettings.read()
    private let audioEffects = AudioEffects()
    private var effectsTask: Task<Void, Never>?
    private var versionTrackID: String?
    private var versionTask: Task<Void, Never>?
    let progress = PlaybackProgress()
    private var sleepTask: Task<Void, Never>?

    /// Настройка «Моей волны»: характер, настроение и язык. Хранится между запусками.
    static var waveSettings: [String] {
        get { UserDefaults.standard.stringArray(forKey: "waveSettings") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "waveSettings") }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var isWave: Bool { wave != nil || offlineWave != nil || context.kind == "radio" }

    private enum EndReason {
        case finished, skipped
    }

    /// Играющий проигрыватель и запасной. В запасном заранее лежит следующий трек: когда
    /// текущий кончается, они меняются местами, и музыка идёт без паузы.
    private var av = AVPlayer()
    private var spare = AVPlayer()
    private var timeObserver: Any?
    /// Плавный переход: прежний трек затихает, новый набирает громкость.
    private var fadeTask: Task<Void, Never>?
    private var fading: AVPlayer?
    /// Для этого трека плавный переход уже начат.
    private var fadedFor: String?
    private var context = PlayContext.various("")
    private var wave: String?
    private struct WaveRequest: Equatable {
        let seeds: [String]
        let name: String
        var id: String { seeds.joined(separator: ",") }
        @MainActor var configuredSeeds: [String] { seeds == ["user:onyourwave"] ? seeds + Player.waveSettings : seeds }
    }
    private var offlineWave: WaveRequest?
    private var startingWave: WaveRequest?
    private var waveRequestTask: Task<Void, Never>?
    /// Семена играющей волны: по ним видно волну-сет, у неё свои точки перехода.
    private var waveSeeds: [String] = []
    private var extendTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?
    /// Волна, что продолжит очередь после последнего трека: её треки дописаны в конец очереди,
    /// а источник сменится на волну, когда до них дойдёт очередь.
    private var continuation: (from: Int, wave: PlayContext, waveId: String, before: PlayContext)?
    private var continueTask: Task<Void, Never>?
    /// Порядок очереди до перемешивания.
    private var original: [Track]?
    /// Растёт с каждой сменой трека: ответ на устаревший запрос отбрасывается.
    private var generation = 0
    private static let tickInterval: Double = 0.15
    private var loadTask: Task<Void, Never>?
    private var preloaded: (id: String, item: AVPlayerItem, version: TrackFiles.Version?)?
    private var preloadTask: Task<Void, Never>?
    private struct NextTrack {
        let track: Track
        let index: Int?
        var moveForward = false
    }
    private var fromPreload = false
    /// Текущий трек играет потоком: если поток не пошёл, он скачивается целиком.
    private var streamed = false
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var pendingSeek: Double?
    /// Счётчик незавершённых перемоток: пока он не ноль, время от плеера не принимается.
    private var seeks = 0
    private var failures = 0
    private var listen: Listen?
    private var artwork: (id: String, art: MPMediaItemArtwork)?
    private var interrupted = false
    private var lastSave = Date.distantPast

    private override init() {
        super.init()
        audioEffects.update(sound)
        av.defaultRate = sound.speed
        spare.defaultRate = sound.speed
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        restore()
        observe()
        remoteCommands()
        $queue.combineLatest($index, $isPlaying)
            .sink { [now] queue, index, playing in
                let id = queue.indices.contains(index) ? queue[index].id : nil
                if now.id != id { now.id = id }
                if now.playing != playing { now.playing = playing }
            }
            .store(in: &bag)
        Connectivity.shared.$online.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.connectivityChanged() }
        }.store(in: &bag)
    }

    // MARK: - Запуск

    /// Играет список с трека start. Недоступные треки в очередь не попадают.
    func play(_ tracks: [Track], at start: Int = 0, context: PlayContext, shuffled: Bool = false) {
        let downloads = Downloads.shared
        func playable(_ track: Track) -> Bool {
            if Connectivity.shared.offline { return downloads.has(track.id) || Uncensor.shared.localAudio(track.id) != nil }
            return !track.unavailable || track.uncensored || downloads.has(track.id) || Uncensor.shared.has(track.id)
        }
        guard !tracks.isEmpty else { return }
        if !shuffled {
            guard tracks.indices.contains(start) else { return }
            // Нажали на трек, что уже звучит из этого же списка: пауза и продолжение, а не заново.
            if let current, current.id == tracks[start].id, now.kind == context.kind, now.item == context.item,
               context.item != nil || now.name == context.name {
                toggle()
                return
            }
            guard playable(tracks[start]) else {
                errorText = "Этот трек недоступен"
                return
            }
        }
        var list = tracks.filter(playable)
        guard !list.isEmpty else {
            errorText = "Здесь нет доступных треков"
            return
        }
        var first = 0
        if shuffled {
            original = list
            list.shuffle()
        } else {
            original = nil
            first = tracks[..<start].filter(playable).count
        }
        endCurrent(.skipped)
        waveRequestTask?.cancel()
        waveRequestTask = nil
        startingWave = nil
        offlineWave = nil
        wave = nil
        waveSeeds = []
        continuation = nil
        shuffle = shuffled
        self.context = context
        contextName = context.name
        mark(context.kind, context.item, context.name)
        queue = list
        saveQueue()
        load(first, autoplay: true)
    }

    /// Запоминает источник очереди для отметок «играет» на карточках.
    private func mark(_ kind: String, _ item: String?, _ name: String) {
        if now.kind != kind { now.kind = kind }
        if now.item != item { now.item = item }
        if now.name != name { now.name = name }
    }

    func ynisonPlayback() -> YnisonProtocol.Playback {
        let position = progress.position.isFinite ? max(0, progress.position) : 0
        let duration = progress.duration.isFinite ? max(0, progress.duration) : 0
        let type: String
        switch context.kind {
        case "album", "playlist", "artist", "radio": type = context.kind.uppercased()
        default: type = "VARIOUS"
        }
        return YnisonProtocol.Playback(songs: queue.map(YnisonProtocol.Song.init(track:)),
                                       index: current == nil ? nil : index, entityID: context.item ?? "",
                                       entityType: type, paused: !isPlaying,
                                       position: position, duration: duration, speed: Double(sound.speed))
    }

    func applyYnison(tracks: [Track], index target: Int, position: Double, playing: Bool,
                     entity: String, entityID: String) {
        guard tracks.indices.contains(target) else { return }
        if target == index, tracks.map(\.id) == queue.map(\.id) {
            if av.currentItem == nil {
                pendingSeek = position
                progress.position = position
            } else if abs(progress.position - position) > 3 {
                seek(to: position)
            }
            if playing && !isPlaying { resume() }
            if !playing && isPlaying { pause() }
            return
        }
        endCurrent(.skipped)
        waveRequestTask?.cancel()
        waveRequestTask = nil
        startingWave = nil
        offlineWave = nil
        wave = nil
        waveSeeds = []
        continuation = nil
        original = nil
        shuffle = false
        let kind = entity.lowercased()
        let catalogSource = ["radio", "album", "playlist", "artist"].contains(kind) && !entityID.isEmpty
        context = PlayContext(kind: catalogSource ? kind : "various", item: catalogSource ? entityID : nil,
                              name: kind == "radio" && entityID == "user:onyourwave" ? "Моя волна" : "С другого устройства")
        contextName = context.name
        mark(context.kind, context.item, context.name)
        queue = tracks
        load(target, autoplay: playing, resume: position)
        saveQueue()
    }

    /// Нажатие на волну: играющая ставится на паузу и снимается с неё, другая — запускается.
    func tapWave(seeds: [String] = ["user:onyourwave"], name: String = "Моя волна") {
        if isWave, now.from("radio", seeds.joined(separator: ",")) {
            toggle()
        } else {
            playWave(seeds: seeds, name: name)
        }
    }

    func playWave(seeds: [String] = ["user:onyourwave"], name: String = "Моя волна") {
        waveRequestTask?.cancel()
        waveRequestTask = nil
        startingWave = nil
        let request = WaveRequest(seeds: seeds, name: name)
        if Connectivity.shared.offline {
            startOfflineWave(request)
            return
        }
        isBuffering = true
        startingWave = request
        let seeds = request.configuredSeeds
        waveRequestTask = Task { [weak self] in
            do {
                let started = try await API.shared.waveNew(seeds: seeds)
                guard let self, !Task.isCancelled else { return }
                guard !started.tracks.isEmpty else { throw TuneError("Волна не прислала треков") }
                self.waveRequestTask = nil
                self.startingWave = nil
                self.offlineWave = nil
                self.endCurrent(.skipped)
                self.wave = started.session
                self.waveSeeds = seeds
                self.continuation = nil
                WaveMix.shared.started()
                WaveWords.shared.reset()
                self.original = nil
                self.shuffle = false
                self.context = PlayContext(kind: "radio", item: seeds.first, name: name)
                self.contextName = name
                self.mark("radio", request.id, name)
                self.queue = started.tracks
                self.saveQueue()
                let session = started.session
                Task.detached(priority: .utility) {
                    try? await API.shared.waveFeedback(session: session, kind: "radioStarted", track: nil, played: nil)
                }
                self.load(0, autoplay: true)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.waveRequestTask = nil
                self.startingWave = nil
                if Connectivity.shared.offline || (error as? APIError)?.isNetwork == true {
                    self.startOfflineWave(request)
                } else {
                    self.isBuffering = false
                    self.errorText = Self.text(error)
                }
            }
        }
    }

    private func startOfflineWave(_ request: WaveRequest) {
        let tracks = Downloads.shared.tracks.shuffled()
        guard !tracks.isEmpty else {
            isBuffering = false
            errorText = "Скачайте музыку, чтобы включать волну без сети"
            return
        }
        endCurrent(.skipped)
        wave = nil
        waveSeeds = request.seeds
        offlineWave = request
        continuation = nil
        original = nil
        shuffle = false
        context = PlayContext(kind: "radio", item: request.seeds.first, name: request.name)
        contextName = request.name
        mark("radio", request.id, request.name)
        queue = tracks
        load(0, autoplay: true)
        saveQueue()
    }

    private func resumeOnlineWave() {
        guard let request = offlineWave, waveRequestTask == nil, !Connectivity.shared.offline else { return }
        let seeds = request.configuredSeeds
        waveRequestTask = Task { [weak self] in
            let started = try? await API.shared.waveNew(seeds: seeds)
            guard let self, !Task.isCancelled else { return }
            self.waveRequestTask = nil
            guard self.offlineWave == request, !Connectivity.shared.offline, let started else { return }
            let tracks = started.tracks.filter { $0.id != self.current?.id }
            guard !tracks.isEmpty else { return }
            self.offlineWave = nil
            self.wave = started.session
            self.waveSeeds = seeds
            let boundary = self.index + 1
            self.queue = Array(self.queue.prefix(boundary)) + tracks
            self.saveQueue()
            self.preloadNext()
            WaveWords.shared.load(queue: self.queue, from: self.index)
            Task.detached(priority: .utility) {
                try? await API.shared.waveFeedback(session: started.session, kind: "radioStarted", track: nil, played: nil)
            }
        }
    }

    private func load(_ target: Int, autoplay: Bool, resume: Double? = nil, viaFile: Bool = false) {
        guard queue.indices.contains(target) else { return }
        loadTask?.cancel()
        loadTask = nil
        advanceTask?.cancel()
        advanceTask = nil
        effectsTask?.cancel()
        effectsTask = nil
        versionTask?.cancel()
        versionTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        if queue[target].id != versionTrackID {
            versionTrackID = nil
            selectedVersion = nil
        }
        let version = selectedVersion
        movedBack = target < index
        index = target
        // Дошли до дописанной волны — играет уже она; вернулись назад — снова альбом или плейлист.
        if let next = continuation {
            let source = target >= next.from ? next.wave : next.before
            if context.kind != source.kind || context.item != source.item {
                context = source
                contextName = source.name
                mark(source.kind, target >= next.from ? next.waveId : source.item, source.name)
            }
        }
        generation += 1
        let turn = generation
        let track = queue[target]
        audibleVersion = nil
        pendingSeek = nil
        isPlaying = autoplay
        isBuffering = autoplay
        progress.position = resume ?? 0
        progress.duration = track.duration
        itemObservation = nil
        let out = crossOut
        crossOut = nil
        // Трек мог уже уходить переходом раньше (вернулись к нему кнопкой «назад»): в этот раз
        // он снова перетекает в следующий.
        fadedFor = nil
        endFade()
        UserDefaults.standard.set(target, forKey: "playerIndex")

        // Следующий трек уже лежит в запасном проигрывателе: меняем их местами.
        if version == nil, !viaFile, resume == nil, let ready = preloaded, ready.id == track.id,
           spare.currentItem === ready.item, !sound.needsAudioMix || ready.item.audioMix != nil {
            preloaded = nil
            audibleVersion = ready.version
            fromPreload = true
            streamed = !((ready.item.asset as? AVURLAsset)?.url.isFileURL ?? true)
            let old = av
            av = spare
            spare = old
            watch()
            let level = Self.level(for: track)
            if autoplay, let out, old.rate > 0, let fade = points(track, duration: ready.item.duration.seconds) {
                // Новый трек нарастает ровно столько, сколько затихает прежний; в волне-сете — по
                // своим точкам и с начала сведения.
                let rise = mixWave ? (fade.inStart, fade.inStop) : (fade.inStart, fade.inStart + (out.1 - out.0))
                if mixWave, fade.inStart > 0 {
                    av.seek(to: CMTime(seconds: fade.inStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                av.volume = 0
                crossfade(from: old, out: out, rise: rise, level: level)
            } else {
                old.pause()
                old.replaceCurrentItem(with: nil)
                av.volume = level
            }
            refreshNowPlaying()
            loadArtwork(track)
            attach(ready.item, track: track, resume: nil)
            return
        }
        preloaded = nil
        spare.replaceCurrentItem(with: nil)
        av.replaceCurrentItem(with: nil)
        av.volume = Self.level(for: track)
        refreshNowPlaying()
        loadArtwork(track)

        // Следующий трек часто запускается с заблокированным экраном: просим у системы время на запрос.
        let background = UIApplication.shared.beginBackgroundTask(withName: "tune.load")
        loadTask = Task { [weak self] in
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            guard let self else { return }
            do {
                let (item, audible) = try await self.makeItem(track, viaFile: viaFile, version: version)
                guard !Task.isCancelled, turn == self.generation else { return }
                self.loadTask = nil
                self.audibleVersion = audible
                self.fromPreload = false
                self.streamed = !viaFile && !((item.asset as? AVURLAsset)?.url.isFileURL ?? true)
                self.attach(item, track: track, resume: resume)
            } catch {
                guard !Task.isCancelled, turn == self.generation else { return }
                self.loadTask = nil
                self.fail(error)
            }
        }
    }

    /// Скачанный файл, кэш или поток. Версия без цензуры и зашифрованный файл сначала
    /// скачиваются целиком.
    private func makeItem(_ track: Track, viaFile: Bool = false, version: TrackFiles.Version? = nil) async throws -> (AVPlayerItem, TrackFiles.Version?) {
        if let version {
            let file = try await TrackFiles.versionFile(for: track, version: version, quality: Settings.streamQuality)
            return (await localAudioItem(file), version)
        }
        if let file = Uncensor.shared.localAudio(track.id) {
            return (await localAudioItem(file), .uncensored)
        }
        if let file = Downloads.shared.fileURL(for: track.id) {
            return (await localAudioItem(file), Downloads.shared.version(for: track.id))
        }
        if Uncensor.shared.has(track.id),
           let file = TrackFiles.existing(id: TrackFiles.Version.uncensored.cacheID(track.id), in: Storage.stream) {
            return (await localAudioItem(file), .uncensored)
        }
        if (!Uncensor.shared.has(track.id) || Connectivity.shared.offline),
           let file = TrackFiles.existing(id: track.id, in: Storage.stream) {
            return (await localAudioItem(file), nil)
        }
        guard !Connectivity.shared.offline else { throw APIError.network("") }
        let source = try await TrackFiles.source(for: track, quality: Settings.streamQuality)
        if !source.needsFile, !viaFile, !sound.needsAudioMix, let url = source.urls.first {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": source.mime])
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = sound.pitchAlgorithm
            return (item, source.version)
        }
        let cacheID = source.version == .uncensored ? source.version.cacheID(track.id) : track.id
        let file = try await TrackFiles.download(id: cacheID, from: source, to: Storage.stream)
        Task.detached(priority: .utility) { TrackFiles.trimStreamCache() }
        return (await localAudioItem(file), source.version)
    }

    private func localAudioItem(_ url: URL) async -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        _ = await audioEffects.install(on: item)
        item.audioTimePitchAlgorithm = sound.pitchAlgorithm
        return item
    }

    func updateSound(_ settings: SoundSettings) {
        guard settings != sound else { return }
        let speedChanged = settings.speed != sound.speed
        let pitchChanged = settings.pitchWithSpeed != sound.pitchWithSpeed
        sound = settings
        sound.save()
        audioEffects.update(sound)
        if pitchChanged {
            av.currentItem?.audioTimePitchAlgorithm = sound.pitchAlgorithm
            spare.currentItem?.audioTimePitchAlgorithm = sound.pitchAlgorithm
        }
        if speedChanged {
            av.defaultRate = sound.speed
            spare.defaultRate = sound.speed
            if av.rate > 0 { av.rate = sound.speed }
            if spare.rate > 0 { spare.rate = sound.speed }
            refreshNowPlaying()
        }
        guard sound.needsAudioMix else {
            effectsTask?.cancel()
            effectsTask = nil
            return
        }
        prepareEffectsForStream()
    }

    private func prepareEffectsForStream() {
        guard effectsTask == nil, streamed, let track = current, let item = av.currentItem,
              item.audioMix == nil, !Settings.offlineMode else { return }
        let turn = generation
        Session.shared.show("Загружаем трек для эффектов")
        effectsTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.makeItem(track, viaFile: true)
                guard !Task.isCancelled, turn == self.generation, self.sound.needsAudioMix else { return }
                self.effectsTask = nil
                let position = self.progress.position
                self.endCurrent(.skipped)
                self.load(self.index, autoplay: self.isPlaying, resume: position, viaFile: true)
            } catch {
                guard !Task.isCancelled, turn == self.generation else { return }
                self.effectsTask = nil
                Session.shared.show("Не удалось загрузить трек для эффектов")
            }
        }
    }

    func selectVersion(_ version: TrackFiles.Version, for track: Track) {
        guard current?.id == track.id, audibleVersion != version,
              version != .yandex || track.yandexAvailable != false else { return }
        versionTask?.cancel()
        let turn = generation
        Session.shared.show("Готовим: \(version.title)")
        versionTask = Task { [weak self] in
            do {
                _ = try await TrackFiles.versionFile(for: track, version: version, quality: Settings.streamQuality)
                guard let self, !Task.isCancelled, turn == self.generation, self.current?.id == track.id else { return }
                self.versionTask = nil
                self.versionTrackID = track.id
                self.selectedVersion = version
                let position = self.progress.position
                self.endCurrent(.skipped)
                self.load(self.index, autoplay: self.isPlaying, resume: position)
                Task.detached(priority: .utility) { TrackFiles.trimStreamCache() }
                Session.shared.show(version.title)
            } catch {
                guard let self, !Task.isCancelled, turn == self.generation else { return }
                self.versionTask = nil
                Session.shared.show(error.localizedDescription)
            }
        }
    }

    private func attach(_ item: AVPlayerItem, track: Track, resume: Double?) {
        if item.audioTimePitchAlgorithm != sound.pitchAlgorithm { item.audioTimePitchAlgorithm = sound.pitchAlgorithm }
        itemObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.itemChanged(item) }
        }
        if av.currentItem !== item {
            av.replaceCurrentItem(with: item)
        } else {
            // Заготовленный трек мог сломаться ещё в запасном проигрывателе, до начала наблюдения.
            itemChanged(item)
        }
        if let resume, resume > 1 {
            av.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        if isPlaying {
            activate()
            av.play()
        }
        if sound.needsAudioMix { prepareEffectsForStream() }
        let started = Listen(track: track, context: context, session: wave)
        listen = started
        let report = started.report(position: 0, first: true)
        let session = wave
        Task.detached(priority: .utility) {
            try? await API.shared.plays([report])
            if let session {
                try? await API.shared.waveFeedback(session: session, kind: "trackStarted", track: track, played: nil)
            }
        }
        if wave != nil, !Connectivity.shared.offline, queue.count - index <= 2 {
            Task { [weak self] in await self?.extendWave() }
        }
        learnLoudness(track)
        preloadNext()
        prepareContinuation()
        if wave != nil {
            WaveWords.shared.load(queue: queue, from: index)
            WaveWords.shared.shown(track)
        }
    }

    /// Заиграл последний трек очереди: заранее просим волну по нему и дописываем её в конец.
    /// Музыка не обрывается, даже если телефон заблокирован (после тишины iOS усыпляет
    /// приложение, и запрос в последний момент уже не уйдёт), а прошлые треки остаются в очереди.
    private func prepareContinuation() {
        guard !Connectivity.shared.offline, !isWave, continuation == nil, continueTask == nil, repeatMode != .all, !sleepAfterTrack,
              let last = current, index == queue.count - 1 else { return }
        let seed = "track:\(last.id)"
        let name = "Волна по треку «\(last.title)»"
        let before = context
        continueTask = Task { [weak self] in
            let started = try? await API.shared.waveNew(seeds: [seed])
            guard let self else { return }
            self.continueTask = nil
            guard !Task.isCancelled, let started, self.wave == nil, self.continuation == nil,
                  self.current?.id == last.id, self.index == self.queue.count - 1 else { return }
            let known = Set(self.queue.map(\.id))
            let more = started.tracks.filter { !known.contains($0.id) }
            guard !more.isEmpty else { return }
            self.continuation = (self.queue.count, PlayContext(kind: "radio", item: seed, name: name), seed, before)
            self.wave = started.session
            self.waveSeeds = [seed]
            self.queue.append(contentsOf: more)
            if self.original != nil { self.original?.append(contentsOf: more) }
            self.saveQueue()
            let session = started.session
            Task.detached(priority: .utility) {
                try? await API.shared.waveFeedback(session: session, kind: "radioStarted", track: nil, played: nil)
            }
            self.preloadNext()
        }
    }

    private func itemChanged(_ item: AVPlayerItem) {
        guard item === av.currentItem else { return }
        switch item.status {
        case .failed:
            fail(item.error ?? TuneError("Не удалось сыграть трек"))
        case .readyToPlay:
            failures = 0
            let length = item.duration.seconds
            if length.isFinite, length > 0 {
                progress.duration = length
            }
            refreshNowPlaying()
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        listen = nil
        if selectedVersion == nil, let track = current, !Downloads.shared.has(track.id),
           Connectivity.shared.offline || (error as? APIError)?.isNetwork == true {
            if isPlaying, let next = nextTrack(localOnly: true) {
                loadNext(next)
            } else {
                errorText = "Этот трек не скачан"
                finishQueue()
            }
            return
        }
        if let version = selectedVersion, let track = current {
            TrackFiles.remove(id: version.cacheID(track.id), in: Storage.stream)
            selectedVersion = nil
            versionTrackID = nil
            Session.shared.show("Выбранная версия не воспроизводится")
            load(index, autoplay: isPlaying, resume: progress.position)
            return
        }
        // Ссылка, заготовленная заранее, могла устареть: берём свежую.
        if fromPreload {
            fromPreload = false
            load(index, autoplay: isPlaying)
            return
        }
        let text = Self.text(error)
        Log.shared.add("плеер: \(queue.indices.contains(index) ? queue[index].id : "?") \(streamed ? "поток" : "файл"): \(text) | \(String(describing: error))")
        // Поток не пошёл — качаем файл целиком и играем его.
        if streamed {
            streamed = false
            load(index, autoplay: isPlaying, viaFile: true)
            return
        }
        failures += 1
        if failures < 3, isPlaying, index + 1 < queue.count {
            errorText = "«\(queue[index].title)»: \(text)"
            load(index + 1, autoplay: true)
        } else {
            errorText = text
            isPlaying = false
            isBuffering = false
            refreshNowPlaying()
        }
    }

    private static func text(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func nextTrack(localOnly: Bool = false) -> NextTrack? {
        if localOnly || Connectivity.shared.offline || offlineWave != nil {
            let downloads = Downloads.shared
            if let next = queue.indices.dropFirst(index + 1).first(where: { downloads.has(queue[$0].id) }) {
                return NextTrack(track: queue[next], index: next, moveForward: next > index + 1)
            }
            if repeatMode == .all, let next = queue.indices.prefix(index).first(where: { downloads.has(queue[$0].id) }) {
                return NextTrack(track: queue[next], index: next)
            }
            // Keep the online queue intact. Only insert the local track when it actually plays.
            let entries = downloads.entries
            guard !entries.isEmpty else { return nil }
            let previous = entries.firstIndex { $0.track.id == current?.id } ?? -1
            let fallback = entries[(previous + 1) % entries.count].track
            return NextTrack(track: fallback, index: nil)
        }
        if queue.indices.contains(index + 1) { return NextTrack(track: queue[index + 1], index: index + 1) }
        if !isWave, repeatMode == .all, let first = queue.first { return NextTrack(track: first, index: 0) }
        return nil
    }

    private func loadNext(_ next: NextTrack) {
        if let target = next.index, !next.moveForward {
            load(target, autoplay: true)
        } else {
            let target = index + 1
            var updated = queue
            if let previous = next.index {
                updated.remove(at: previous)
                if let boundary = continuation?.from, previous < boundary { continuation?.from -= 1 }
            }
            updated.insert(next.track, at: target)
            if let boundary = continuation?.from, target <= boundary { continuation?.from += 1 }
            queue = updated
            load(target, autoplay: true)
            saveQueue()
        }
    }

    private func preloadNext() {
        preloadTask?.cancel()
        preloadTask = nil
        guard let next = nextTrack(), next.track.id != current?.id else {
            preloaded = nil
            return
        }
        let track = next.track
        let needsLocal = Connectivity.shared.offline || offlineWave != nil
        if let ready = preloaded, ready.id == track.id,
           !needsLocal || (ready.item.asset as? AVURLAsset)?.url.isFileURL == true { return }
        preloaded = nil
        let turn = generation
        preloadTask = Task { [weak self] in
            guard let self else { return }
            if needsLocal, !Downloads.shared.has(track.id) { return }
            guard let (item, version) = try? await self.makeItem(track), !Task.isCancelled, turn == self.generation else { return }
            // Запасной проигрыватель ещё доигрывает затихающий трек: ждём конца перехода.
            await self.fadeTask?.value
            guard !Task.isCancelled, turn == self.generation, self.nextTrack()?.track.id == track.id else { return }
            self.spare.pause()
            self.spare.volume = 0
            self.spare.replaceCurrentItem(with: item)
            self.preloaded = (track.id, item, version)
        }
    }

    func connectivityChanged() {
        if Connectivity.shared.offline, let request = startingWave {
            waveRequestTask?.cancel()
            waveRequestTask = nil
            startingWave = nil
            startOfflineWave(request)
            return
        }
        guard current != nil else { return }
        if Connectivity.shared.offline {
            continueTask?.cancel()
            extendTask?.cancel()
            if offlineWave != nil {
                waveRequestTask?.cancel()
                waveRequestTask = nil
            }
            recoverOfflineStream()
        } else {
            resumeOnlineWave()
            if wave != nil, queue.count - index <= 2 {
                Task { [weak self] in await self?.extendWave() }
            } else {
                prepareContinuation()
            }
        }
        preloadNext()
    }

    private func recoverOfflineStream() {
        guard isPlaying, let track = current, isBuffering || av.currentItem == nil,
              av.currentItem == nil || streamed else { return }
        if Downloads.shared.has(track.id) {
            endCurrent(.skipped)
            selectedVersion = nil
            versionTrackID = nil
            load(index, autoplay: true, resume: progress.position)
        } else if let next = nextTrack(localOnly: true) {
            endCurrent(.skipped)
            loadNext(next)
        } else {
            endCurrent(.skipped)
            finishQueue()
        }
    }

    // MARK: - Громкость и плавный переход

    /// Окно затухания играющего трека: задаётся, когда пора переходить к следующему.
    private var crossOut: (Double, Double)?

    private var mixWave: Bool {
        wave != nil && waveSeeds.contains { $0.hasPrefix("mix-") }
    }

    /// Множитель громкости, который приводит трек к −14 LUFS по его R128, как в Tune Native:
    /// тихий поднимается не выше, чем позволяет пик (−1 dBTP), громкий — не тише, чем на 12 дБ.
    /// Системный проигрыватель громче 100% не играет, поэтому подъём тихих записей ограничен.
    private static func level(for track: Track) -> Float {
        guard Settings.normalize, let found = Loudness.shared.value(track) else { return 1 }
        var db = -14 - found.i
        if let tp = found.tp { db = min(db, -1 - tp) }
        db = min(max(db, -12), 6)
        return Float(min(1, pow(10, db / 20)))
    }

    /// Настройку выравнивания поменяли: громкость играющего трека пересчитывается сразу.
    func settingsChanged() {
        guard fadeTask == nil, let track = current else { return }
        av.volume = Self.level(for: track)
        learnLoudness(track)
    }

    /// Точки перехода трека. «Авто»: разметка Яндекса, в волне-сете своя, плотнее обычной;
    /// без разметки — ровный переход на 6 секунд, чтобы перетекали любые треки. С заданной
    /// длиной — ровный переход на неё. Короткие треки, подкасты и книги без перехода.
    private func points(_ track: Track, duration: Double) -> FadePoints? {
        let length = duration.isFinite && duration > 0 ? duration : track.duration
        let setting = Settings.crossfade
        if setting > 0 {
            let span = Double(setting)
            guard length >= 30 else { return nil }
            return FadePoints(inStart: 0, inStop: span, outStart: length - span, outStop: length)
        }
        if let marked = mixWave ? (track.mixFade ?? track.fade) : track.fade { return marked }
        guard length >= 30 else { return nil }
        return FadePoints(inStart: 0, inStop: 6, outStart: length - 6, outStop: length)
    }

    /// Когда затухает играющий трек: в конце его окна и не дольше 6 секунд — точки Яндекса
    /// бывают и на 10–15 секунд, трек тогда уходил задолго до конца. В волне-сете переход —
    /// часть сведения, его длина не режется.
    private func window(_ fade: FadePoints) -> (Double, Double) {
        if mixWave || Settings.crossfade > 0 { return (fade.outStart, fade.outStop) }
        return (max(fade.outStart, fade.outStop - 6), fade.outStop)
    }

    /// Доля пути от начала окна до конца, от 0 до 1.
    private static func part(_ position: Double, _ range: (Double, Double)) -> Float {
        if range.1 <= range.0 { return position >= range.0 ? 1 : 0 }
        return Float(min(max((position - range.0) / (range.1 - range.0), 0), 1))
    }

    /// Громкость трека неизвестна (скачан или сохранён до того, как она стала приходить):
    /// узнаём её и плавно подводим звук к нужному уровню.
    private func learnLoudness(_ track: Track) {
        guard Settings.normalize, Loudness.shared.value(track) == nil else { return }
        Task { [weak self] in
            guard await Loudness.shared.resolve(track) != nil, let self else { return }
            guard self.current?.id == track.id, self.fadeTask == nil else { return }
            let player = self.av
            let from = player.volume
            let to = Self.level(for: track)
            for step in 1...30 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard self.current?.id == track.id, self.fadeTask == nil, self.av === player else { return }
                player.volume = from + (to - from) * Float(step) / 30
            }
        }
    }

    /// Переход по месту в каждом треке, а не по таймеру: прежний затихает в своём окне и там
    /// кончается, новый нарастает в своём. Громкость идёт по S-кривой — в начале и в конце
    /// окна меняется медленно, без рывка, а громкости двух треков в сумме дают единицу.
    private func crossfade(from old: AVPlayer, out: (Double, Double), rise: (Double, Double), level: Float) {
        fading = old
        let start = old.volume
        let player = av
        fadeTask = Task { [weak self] in
            var gone = false
            while !Task.isCancelled {
                if !gone {
                    let was = old.currentTime().seconds
                    if !was.isFinite || was >= out.1 || old.currentItem == nil || old.timeControlStatus == .paused {
                        gone = true
                        old.pause()
                        old.replaceCurrentItem(with: nil)
                        old.volume = 0
                    } else {
                        old.volume = start * pow(cos(Self.part(was, out) * .pi / 2), 2)
                    }
                }
                let now = player.currentTime().seconds
                if now.isFinite {
                    player.volume = level * pow(sin(Self.part(now, rise) * .pi / 2), 2)
                }
                if gone, !now.isFinite || now >= rise.1 { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.endFade()
        }
    }

    /// Конец перехода, в том числе досрочный: прежний трек замолкает, новый играет в полную силу.
    private func endFade() {
        guard let old = fading else { return }
        fading = nil
        fadeTask?.cancel()
        fadeTask = nil
        old.pause()
        old.replaceCurrentItem(with: nil)
        old.volume = 0
        if let track = current { av.volume = Self.level(for: track) }
    }

    /// Следит за играющим проигрывателем: время и состояние буфера.
    private func watch() {
        if let timeObserver { spare.removeTimeObserver(timeObserver) }
        let source = av
        timeObserver = source.addPeriodicTimeObserver(forInterval: CMTime(seconds: Self.tickInterval, preferredTimescale: 600), queue: .main) { [weak self, weak source] time in
            let seconds = time.seconds
            Task { @MainActor [weak self, weak source] in
                guard let self, self.av === source else { return }
                self.tick(seconds)
            }
        }
        statusObservation = source.observe(\.timeControlStatus) { [weak self] player, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, self.av === player else { return }
                self.statusChanged()
            }
        }
    }

    // MARK: - Управление

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        advanceTask?.cancel()
        advanceTask = nil
        isPlaying = false
        isBuffering = false
        endFade()
        av.pause()
        listen?.pause = true
        refreshNowPlaying()
        savePosition()
    }

    func resume() {
        guard current != nil else { return }
        resumeOnlineWave()
        if av.currentItem == nil {
            load(index, autoplay: true, resume: pendingSeek)
            return
        }
        isPlaying = true
        activate()
        av.play()
        refreshNowPlaying()
    }

    func next() {
        guard nextTrack() != nil || isWave else { return }
        endCurrent(.skipped)
        advance(auto: false)
    }

    func updateUploadedMetadata(id: String, title: String, artist: String) {
        guard queue.contains(where: { $0.id == id }) else { return }
        queue = queue.map { $0.id == id ? $0.withUploadedMetadata(title: title, artist: artist) : $0 }
        refreshNowPlaying()
        saveQueue()
    }

    func previous() {
        let target = Connectivity.shared.offline ? queue.indices.prefix(index).last(where: { Downloads.shared.has(queue[$0].id) })
            : (index > 0 ? index - 1 : nil)
        if progress.position > 3 || target == nil {
            seek(to: 0)
        } else if let target {
            endCurrent(.skipped)
            load(target, autoplay: true)
        }
    }

    func jump(to target: Int) {
        guard target != index, queue.indices.contains(target) else { return }
        if Connectivity.shared.offline, !Downloads.shared.has(queue[target].id) {
            errorText = "Этот трек не скачан"
            return
        }
        endCurrent(.skipped)
        load(target, autoplay: true)
    }

    func seek(to seconds: Double) {
        progress.position = seconds
        listen?.seek = true
        guard av.currentItem != nil else {
            pendingSeek = seconds
            return
        }
        // Пока перемотка не завершилась, плеер ещё сообщает старое время: его пропускаем,
        // иначе полоска на миг прыгает назад.
        seeks += 1
        let mine = seeks
        av.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.seeks == mine { self.seeks = 0 }
                self.refreshNowPlaying()
            }
        }
    }

    func stop() {
        advanceTask?.cancel()
        advanceTask = nil
        loadTask?.cancel()
        loadTask = nil
        preloadTask?.cancel()
        preloadTask = nil
        waveRequestTask?.cancel()
        waveRequestTask = nil
        startingWave = nil
        offlineWave = nil
        effectsTask?.cancel()
        effectsTask = nil
        versionTask?.cancel()
        versionTask = nil
        selectedVersion = nil
        versionTrackID = nil
        endCurrent(.skipped)
        audibleVersion = nil
        generation += 1
        itemObservation = nil
        endFade()
        av.replaceCurrentItem(with: nil)
        spare.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        wave = nil
        waveSeeds = []
        continuation = nil
        original = nil
        preloaded = nil
        isPlaying = false
        isBuffering = false
        contextName = ""
        mark("", nil, "")
        refreshNowPlaying()
        Storage.remove("player.json")
    }

    func toggleShuffle() {
        guard queue.indices.contains(index) else { return }
        if shuffle {
            shuffle = false
            if let original, let position = original.firstIndex(where: { $0.id == queue[index].id }) {
                queue = original
                index = position
            }
            original = nil
        } else {
            shuffle = true
            original = queue
            let playing = queue[index]
            var rest = queue
            rest.remove(at: index)
            rest.shuffle()
            queue = [playing] + rest
            index = 0
        }
        preloadNext()
        saveQueue()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func playNext(_ track: Track) {
        guard !queue.isEmpty else {
            play([track], context: .various("Очередь"))
            return
        }
        queue.insert(track, at: index + 1)
        original = nil
        preloadNext()
        saveQueue()
    }

    func addToQueue(_ track: Track) {
        guard !queue.isEmpty else {
            play([track], context: .various("Очередь"))
            return
        }
        queue.append(track)
        original = nil
        if index + 2 == queue.count { preloadNext() }
        saveQueue()
    }

    /// Убирает из очереди всё, что стоит после играющего трека.
    func clearUpcoming() {
        guard index + 1 < queue.count else { return }
        queue = Array(queue[...index])
        original = nil
        preloadNext()
        saveQueue()
    }

    func removeFromQueue(_ offsets: IndexSet) {
        for position in offsets.sorted(by: >) where position != index && queue.indices.contains(position) {
            queue.remove(at: position)
            if position < index { index -= 1 }
        }
        original = nil
        preloadNext()
        saveQueue()
    }

    func moveInQueue(from offsets: IndexSet, to target: Int) {
        var marked = queue.enumerated().map { (current: $0.offset == index, track: $0.element) }
        marked.move(fromOffsets: offsets, toOffset: target)
        queue = marked.map(\.track)
        index = marked.firstIndex { $0.current } ?? 0
        original = nil
        preloadNext()
        saveQueue()
    }

    /// Дизлайк текущему треку: он пропускается и больше не попадётся в волне.
    func dislikeCurrent() {
        guard let track = current else { return }
        if Session.shared.toggleDislike(track) { next() }
    }

    /// Остановить музыку через столько минут; nil — выключить таймер.
    func setSleep(minutes: Int?) {
        sleepTask?.cancel()
        sleepAfterTrack = false
        guard let minutes else {
            sleepAt = nil
            return
        }
        sleepAt = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sleepAt = nil
            self.pause()
        }
    }

    func sleepAfterCurrentTrack() {
        sleepTask?.cancel()
        sleepAt = nil
        sleepAfterTrack = true
    }

    // MARK: - Конец трека и волна

    private func endCurrent(_ reason: EndReason) {
        guard let finished = listen else { return }
        listen = nil
        let restoredInWave = finished.context.kind == "radio" && finished.track.uncensored
            && finished.track.yandexAvailable == false
        Stats.shared.add(finished.track, seconds: finished.played,
                         waveAccount: restoredInWave ? Session.shared.profile?.uid : nil)
        let position = reason == .finished ? finished.track.duration : progress.position
        let report = finished.report(position: position, first: false)
        let kind = reason == .finished ? "trackFinished" : "skip"
        // Реакции в волне — вкус по исполнителям для удалённых треков.
        if finished.session != nil {
            WaveTaste.shared.react(kind, track: finished.track, played: finished.played)
        }
        Task.detached(priority: .utility) {
            try? await API.shared.plays([report])
            if let session = finished.session {
                try? await API.shared.waveFeedback(session: session, kind: kind, track: finished.track, played: finished.played)
            }
        }
    }

    private func trackEnded() {
        endCurrent(.finished)
        if sleepAfterTrack {
            sleepAfterTrack = false
            finishQueue()
            return
        }
        if repeatMode == .one, let track = current {
            crossOut = nil
            av.seek(to: .zero)
            av.play()
            listen = Listen(track: track, context: context, session: wave)
            return
        }
        advance(auto: true)
    }

    private func advance(auto: Bool) {
        if let next = nextTrack() {
            if offlineWave != nil { resumeOnlineWave() }
            loadNext(next)
            return
        }
        if Connectivity.shared.offline || offlineWave != nil {
            finishQueue()
            return
        }
        if wave == nil, context.kind == "radio", let seeds = context.item, !seeds.isEmpty {
            playWave(seeds: seeds.components(separatedBy: ","), name: context.name)
            return
        }
        if wave != nil {
            isBuffering = true
            let turn = generation
            advanceTask?.cancel()
            advanceTask = Task { [weak self] in
                guard let self else { return }
                await self.extendWave()
                guard !Task.isCancelled, turn == self.generation else { return }
                self.advanceTask = nil
                if let next = self.nextTrack() {
                    self.loadNext(next)
                } else if Connectivity.shared.offline {
                    self.finishQueue()
                } else if self.now.kind == "radio", let seeds = self.now.item, !seeds.isEmpty {
                    // Сессия волны устарела (например, после перезапуска): начинаем её заново.
                    self.playWave(seeds: seeds.components(separatedBy: ","), name: self.now.name)
                } else {
                    self.continueAfterQueue()
                }
            }
            return
        }
        if auto { continueAfterQueue() }
    }

    /// Очередь кончилась сама: музыка не обрывается, а продолжается волной по последнему
    /// треку — так же, как в приложении Яндекса.
    private func continueAfterQueue() {
        guard current != nil, !sleepAfterTrack else {
            finishQueue()
            return
        }
        // Обычно волна уже дописана заранее; не успела (не было сети) — просим сейчас.
        prepareContinuation()
        guard let task = continueTask else {
            finishQueue()
            return
        }
        isBuffering = true
        let turn = generation
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            await task.value
            guard let self, !Task.isCancelled, turn == self.generation else { return }
            self.advanceTask = nil
            if let next = self.nextTrack() {
                self.loadNext(next)
            } else {
                self.finishQueue()
            }
        }
    }

    private func finishQueue() {
        loadTask?.cancel()
        loadTask = nil
        crossOut = nil
        isPlaying = false
        isBuffering = false
        av.pause()
        av.seek(to: .zero)
        progress.position = 0
        refreshNowPlaying()
    }

    /// Следующая пачка волны. Второй вызов ждёт первого, а не шлёт запрос ещё раз.
    private func extendWave() async {
        if let task = extendTask {
            await task.value
            return
        }
        guard !Connectivity.shared.offline, let session = wave else { return }
        let shown = queue.map(\.fullId)
        WaveMix.shared.refill(queue: queue)
        let task = Task { [weak self] in
            let more = try? await API.shared.waveMore(session: session, queue: shown)
            guard let self, !Task.isCancelled, let more, self.wave == session else { return }
            let known = Set(self.queue.map(\.id))
            var fresh = more.filter { !known.contains($0.id) }
            // Удалённый трек по вкусу, иначе иногда — свой.
            if let extra = WaveMix.shared.pick(known: known, count: fresh.count, queue: self.queue) {
                fresh.insert(extra, at: 0)
            }
            self.queue.append(contentsOf: fresh)
            self.saveQueue()
            WaveWords.shared.load(queue: self.queue, from: self.index)
        }
        extendTask = task
        await task.value
        extendTask = nil
    }

    // MARK: - Система: звук, экран блокировки, наушники

    private func activate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observe() {
        watch()
        let center = NotificationCenter.default
        center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, let item, item === self.av.currentItem else { return }
                self.trackEnded()
            }
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            let shouldResume = options?.contains(.shouldResume) ?? false
            Task { @MainActor [weak self] in self?.interruption(began: type == .began, shouldResume: shouldResume) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            guard reason == .oldDeviceUnavailable else { return }
            // Наушники отключили — музыка не должна заиграть из динамика.
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.savePosition() }
        }
    }

    private func tick(_ seconds: Double) {
        guard av.currentItem != nil, seconds.isFinite, seeks == 0 else { return }
        progress.position = seconds
        if av.rate > 0 {
            listen?.played += Self.tickInterval
        }
        // Плавный переход: трек дошёл до начала своего окна затухания, и у следующего
        // тоже есть точки перехода. Повтор одного трека переходом не идёт.
        if Settings.crossfade != 0, av.rate > 0, repeatMode != .one, !sleepAfterTrack, let track = current, fadedFor != track.id,
           let ready = preloaded, let next = nextTrack(), next.track.id == ready.id,
           ready.item.status == .readyToPlay, let fade = points(track, duration: progress.duration),
           points(next.track, duration: ready.item.duration.seconds) != nil {
            let out = window(fade)
            if seconds >= out.0, seconds < out.1 {
                fadedFor = track.id
                crossOut = out
                trackEnded()
            }
        }
        if Date().timeIntervalSince(lastSave) > 15 {
            savePosition()
        }
    }

    private func statusChanged() {
        guard av.currentItem != nil else { return }
        isBuffering = isPlaying && av.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if Connectivity.shared.offline, isBuffering, streamed {
            recoverOfflineStream()
            return
        }
        refreshNowPlaying()
    }

    private func interruption(began: Bool, shouldResume: Bool) {
        if began {
            if isPlaying {
                interrupted = true
                pause()
            }
        } else {
            if interrupted, shouldResume { resume() }
            interrupted = false
        }
    }

    private func remoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        center.likeCommand.localizedTitle = "Нравится"
        center.dislikeCommand.localizedTitle = "Не нравится"
        center.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let track = self?.current else { return }
                Session.shared.toggleLike(track)
            }
            return .success
        }
        let session = Session.shared
        now.$id.combineLatest(session.$likedIds, session.$profile)
            .sink { id, likedIDs, profile in
                let enabled = id != nil && profile != nil
                let liked = id.map { likedIDs.contains($0) } ?? false
                center.likeCommand.isEnabled = enabled
                center.likeCommand.isActive = enabled && liked
            }
            .store(in: &bag)
        center.dislikeCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let track = self.current, !Session.shared.disliked.contains(track.id) else { return }
                self.dislikeCurrent()
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
    }

    func refreshPlaybackActivity() {
        if #available(iOS 16.2, *) {
            let time = av.currentTime().seconds
            let elapsed = time.isFinite && av.currentItem != nil ? time : progress.position
            let rate = av.timeControlStatus == .playing ? Double(av.rate) : 0
            PlaybackActivity.shared.refresh(track: current, playing: isPlaying, elapsed: elapsed,
                                            duration: progress.duration, rate: rate)
        }
    }

    private func refreshNowPlaying() {
        refreshPlaybackActivity()
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var elapsed = progress.position
        if av.currentItem != nil {
            let now = av.currentTime().seconds
            if now.isFinite { elapsed = max(0, now) }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.fullTitle,
            MPMediaItemPropertyArtist: track.artists,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: progress.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying && av.timeControlStatus == .playing) ? av.rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: sound.speed,
        ]
        if let artwork, artwork.id == track.id {
            info[MPMediaItemPropertyArtwork] = artwork.art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ track: Track) {
        if artwork?.id == track.id { return }
        Task { [weak self] in
            guard let image = await ImageLoader.shared.load(track.cover, side: 800) else { return }
            guard let self, self.current?.id == track.id else { return }
            self.artwork = (track.id, Self.makeArtwork(image))
            self.refreshNowPlaying()
        }
    }

    /// Система зовёт обработчик обложки из своего потока, поэтому он создаётся вне главного актора.
    private nonisolated static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Очередь для снимков экрана: ничего не играет и не грузится.
    func showDemo(_ tracks: [Track], name: String) {
        guard tracks.count > 2 else { return }
        queue = tracks
        index = 2
        contextName = name
        mark("various", nil, name)
        // На снимке главной играет волна по настроению, на полке — альбом.
        if Demo.screen == "home", let wave = Demo.data.waves.first {
            contextName = wave.title
            mark("radio", wave.id, wave.title)
        } else if Demo.screen == "shelf", let album = Demo.data.releases.first {
            contextName = album.title
            mark("album", album.id, album.title)
        }
        isPlaying = true
        progress.duration = tracks[2].duration
        progress.position = tracks[2].duration * 0.37
        loadArtwork(tracks[2])
    }

    // MARK: - Сохранение очереди между запусками

    private struct Saved: Codable {
        var queue: [Track]
        var name: String
        /// Откуда играла очередь: после перезапуска на главной и в списках видно, что играет.
        var kind: String?
        var item: String?
        /// Волна: её сессия и затравки, чтобы она продолжилась и после перезапуска.
        var session: String?
        var seeds: [String]?
    }

    private func saveQueue() {
        if Demo.on { return }
        let saved = Saved(queue: queue, name: contextName, kind: now.kind, item: now.item, session: wave, seeds: waveSeeds)
        Task.detached(priority: .utility) { Storage.save(saved, "player.json") }
        savePosition()
    }

    private func savePosition() {
        lastSave = Date()
        UserDefaults.standard.set(index, forKey: "playerIndex")
        UserDefaults.standard.set(progress.position, forKey: "playerPosition")
    }

    private func restore() {
        if Demo.on { return }
        guard let saved: Saved = Storage.load("player.json"), !saved.queue.isEmpty else { return }
        queue = saved.queue
        contextName = saved.name
        let kind = saved.kind.flatMap { $0.isEmpty ? nil : $0 } ?? "various"
        context = PlayContext(kind: kind, item: saved.item, name: saved.name)
        mark(kind, saved.item, saved.name)
        if kind == "radio" {
            wave = saved.session
            waveSeeds = saved.seeds ?? []
            if wave == nil, !waveSeeds.isEmpty { offlineWave = WaveRequest(seeds: waveSeeds, name: saved.name) }
        }
        index = min(max(UserDefaults.standard.integer(forKey: "playerIndex"), 0), saved.queue.count - 1)
        let position = UserDefaults.standard.double(forKey: "playerPosition")
        progress.position = position
        progress.duration = queue[index].duration
        pendingSeek = position
    }
}
