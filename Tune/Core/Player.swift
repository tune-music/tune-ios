import AVFoundation
import MediaPlayer
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

@MainActor
final class Player: NSObject, ObservableObject {
    static let shared = Player()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var contextName = ""
    @Published var errorText: String?
    let progress = PlaybackProgress()

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var isWave: Bool { wave != nil }

    private enum EndReason {
        case finished, skipped
    }

    private let av = AVPlayer()
    private var context = PlayContext.various("")
    private var wave: String?
    private var extendTask: Task<Void, Never>?
    /// Порядок очереди до перемешивания.
    private var original: [Track]?
    /// Растёт с каждой сменой трека: ответ на устаревший запрос отбрасывается.
    private var generation = 0
    private var preloaded: (id: String, item: AVPlayerItem)?
    private var fromPreload = false
    /// Текущий трек играет потоком: если поток не пошёл, он скачивается целиком.
    private var streamed = false
    private var itemObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var pendingSeek: Double?
    private var failures = 0
    private var listen: Listen?
    private var artwork: (id: String, art: MPMediaItemArtwork)?
    private var interrupted = false
    private var lastSave = Date.distantPast

    private override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        restore()
        observe()
        remoteCommands()
    }

    // MARK: - Запуск

    /// Играет список с трека start. Недоступные треки в очередь не попадают.
    func play(_ tracks: [Track], at start: Int = 0, context: PlayContext, shuffled: Bool = false) {
        let downloads = Downloads.shared
        func playable(_ track: Track) -> Bool {
            !track.unavailable || track.uncensored || downloads.has(track.id)
        }
        guard !tracks.isEmpty else { return }
        if !shuffled {
            guard tracks.indices.contains(start) else { return }
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
        wave = nil
        shuffle = shuffled
        self.context = context
        contextName = context.name
        queue = list
        saveQueue()
        load(first, autoplay: true)
    }

    func playWave(seeds: [String] = ["user:onyourwave"], name: String = "Моя волна") {
        isBuffering = true
        Task { [weak self] in
            do {
                let started = try await API.shared.waveNew(seeds: seeds)
                guard let self else { return }
                guard !started.tracks.isEmpty else { throw TuneError("Волна не прислала треков") }
                self.endCurrent(.skipped)
                self.wave = started.session
                self.original = nil
                self.shuffle = false
                self.context = PlayContext(kind: "radio", item: seeds.first, name: name)
                self.contextName = name
                self.queue = started.tracks
                self.saveQueue()
                let session = started.session
                Task.detached(priority: .utility) {
                    try? await API.shared.waveFeedback(session: session, kind: "radioStarted", track: nil, played: nil)
                }
                self.load(0, autoplay: true)
            } catch {
                self?.isBuffering = false
                self?.errorText = Self.text(error)
            }
        }
    }

    private func load(_ target: Int, autoplay: Bool, resume: Double? = nil, viaFile: Bool = false) {
        guard queue.indices.contains(target) else { return }
        index = target
        generation += 1
        let turn = generation
        let track = queue[target]
        pendingSeek = nil
        isPlaying = autoplay
        isBuffering = autoplay
        progress.position = resume ?? 0
        progress.duration = track.duration
        itemObservation = nil
        av.replaceCurrentItem(with: nil)
        refreshNowPlaying()
        loadArtwork(track)
        UserDefaults.standard.set(target, forKey: "playerIndex")

        // Следующий трек часто запускается с заблокированным экраном: просим у системы время на запрос.
        let background = UIApplication.shared.beginBackgroundTask(withName: "tune.load")
        Task { [weak self] in
            defer {
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            }
            guard let self else { return }
            do {
                let item: AVPlayerItem
                if !viaFile, let ready = self.preloaded, ready.id == track.id {
                    item = ready.item
                    self.fromPreload = true
                } else {
                    item = try await self.makeItem(track, viaFile: viaFile)
                    self.fromPreload = false
                }
                self.streamed = !viaFile && !((item.asset as? AVURLAsset)?.url.isFileURL ?? true)
                self.preloaded = nil
                guard turn == self.generation else { return }
                self.attach(item, track: track, resume: resume)
            } catch {
                guard turn == self.generation else { return }
                self.fail(error)
            }
        }
    }

    /// Скачанный файл, кэш или поток. Версия без цензуры и зашифрованный файл сначала
    /// скачиваются целиком.
    private func makeItem(_ track: Track, viaFile: Bool = false) async throws -> AVPlayerItem {
        if let file = Downloads.shared.fileURL(for: track.id) {
            return AVPlayerItem(url: file)
        }
        if let file = TrackFiles.existing(id: track.id, in: Storage.stream) {
            return AVPlayerItem(url: file)
        }
        let source = try await TrackFiles.source(for: track, quality: Settings.streamQuality)
        if !source.needsFile, !viaFile, let url = source.urls.first {
            let asset = AVURLAsset(url: url, options: ["AVURLAssetOutOfBandMIMETypeKey": source.mime])
            return AVPlayerItem(asset: asset)
        }
        let file = try await TrackFiles.download(id: track.id, from: source, to: Storage.stream)
        Task.detached(priority: .utility) { TrackFiles.trimStreamCache() }
        return AVPlayerItem(url: file)
    }

    private func attach(_ item: AVPlayerItem, track: Track, resume: Double?) {
        itemObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.itemChanged(item) }
        }
        av.replaceCurrentItem(with: item)
        if let resume, resume > 1 {
            av.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        if isPlaying {
            activate()
            av.play()
        }
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
        if wave != nil, queue.count - index <= 2 {
            Task { [weak self] in await self?.extendWave() }
        }
        preloadNext()
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

    private func preloadNext() {
        preloaded = nil
        let next = index + 1
        guard queue.indices.contains(next) else { return }
        let track = queue[next]
        let turn = generation
        Task { [weak self] in
            guard let self, let item = try? await self.makeItem(track), turn == self.generation else { return }
            self.preloaded = (track.id, item)
        }
    }

    // MARK: - Управление

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        isPlaying = false
        isBuffering = false
        av.pause()
        listen?.pause = true
        refreshNowPlaying()
        savePosition()
    }

    func resume() {
        guard current != nil else { return }
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
        guard index + 1 < queue.count || wave != nil || repeatMode == .all else { return }
        endCurrent(.skipped)
        advance(auto: false)
    }

    func previous() {
        if progress.position > 3 || index == 0 {
            seek(to: 0)
        } else {
            endCurrent(.skipped)
            load(index - 1, autoplay: true)
        }
    }

    func jump(to target: Int) {
        guard target != index, queue.indices.contains(target) else { return }
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
        av.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshNowPlaying() }
        }
    }

    func stop() {
        endCurrent(.skipped)
        generation += 1
        itemObservation = nil
        av.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        wave = nil
        original = nil
        preloaded = nil
        isPlaying = false
        isBuffering = false
        contextName = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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

    // MARK: - Конец трека и волна

    private func endCurrent(_ reason: EndReason) {
        guard let finished = listen else { return }
        listen = nil
        let position = reason == .finished ? finished.track.duration : progress.position
        let report = finished.report(position: position, first: false)
        let kind = reason == .finished ? "trackFinished" : "skip"
        Task.detached(priority: .utility) {
            try? await API.shared.plays([report])
            if let session = finished.session {
                try? await API.shared.waveFeedback(session: session, kind: kind, track: finished.track, played: finished.played)
            }
        }
    }

    private func trackEnded() {
        endCurrent(.finished)
        if repeatMode == .one, let track = current {
            av.seek(to: .zero)
            av.play()
            listen = Listen(track: track, context: context, session: wave)
            return
        }
        advance(auto: true)
    }

    private func advance(auto: Bool) {
        if index + 1 < queue.count {
            load(index + 1, autoplay: true)
            return
        }
        if wave != nil {
            isBuffering = true
            Task { [weak self] in
                guard let self else { return }
                await self.extendWave()
                if self.index + 1 < self.queue.count {
                    self.load(self.index + 1, autoplay: true)
                } else {
                    self.finishQueue()
                }
            }
            return
        }
        if repeatMode == .all, !queue.isEmpty {
            load(0, autoplay: true)
            return
        }
        if auto { finishQueue() }
    }

    private func finishQueue() {
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
        guard let session = wave else { return }
        let shown = queue.map(\.fullId)
        let task = Task { [weak self] in
            let more = try? await API.shared.waveMore(session: session, queue: shown)
            guard let self, let more, self.wave == session else { return }
            let known = Set(self.queue.map(\.id))
            self.queue.append(contentsOf: more.filter { !known.contains($0.id) })
            self.saveQueue()
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
        _ = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in self?.tick(seconds) }
        }
        statusObservation = av.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.statusChanged() }
        }
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
        guard av.currentItem != nil, seconds.isFinite else { return }
        progress.position = seconds
        if av.rate > 0 {
            listen?.played += 0.5
        }
        if Date().timeIntervalSince(lastSave) > 15 {
            savePosition()
        }
    }

    private func statusChanged() {
        guard av.currentItem != nil else { return }
        isBuffering = isPlaying && av.timeControlStatus == .waitingToPlayAtSpecifiedRate
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
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak self] in self?.seek(to: seconds) }
            return .success
        }
    }

    private func refreshNowPlaying() {
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
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying && av.timeControlStatus == .playing) ? 1.0 : 0.0,
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
        isPlaying = true
        progress.duration = tracks[2].duration
        progress.position = tracks[2].duration * 0.37
        loadArtwork(tracks[2])
    }

    // MARK: - Сохранение очереди между запусками

    private struct Saved: Codable {
        var queue: [Track]
        var name: String
    }

    private func saveQueue() {
        if Demo.on { return }
        let saved = Saved(queue: queue, name: contextName)
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
        context = .various(saved.name)
        index = min(max(UserDefaults.standard.integer(forKey: "playerIndex"), 0), saved.queue.count - 1)
        let position = UserDefaults.standard.double(forKey: "playerPosition")
        progress.position = position
        progress.duration = queue[index].duration
        pendingSeek = position
    }
}
