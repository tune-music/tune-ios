import AVFoundation
import CoreMedia
import Foundation

enum WaveDiversity {
    case any, favorite, discover, popular
}

struct WaveContext {
    var targetMood: AudioMood? = nil
    var diversity: WaveDiversity = .any
    var focusArtist: String? = nil
    var blockedWave = false
    var centroid: AudioProfile? = nil

    static func fromSeeds(_ seeds: [String], recentProfiles: [AudioProfile]) -> WaveContext {
        var ctx = WaveContext()
        for seed in seeds {
            switch seed {
            case "settingMoodEnergy:sad", "mood:sad": ctx.targetMood = .sad
            case "settingMoodEnergy:calm", "activity:fall-asleep", "activity:work-background", "mood:calm", "mood:chill": ctx.targetMood = .calm
            case "settingMoodEnergy:active", "activity:workout", "activity:wake-up", "mood:energetic", "mood:workout": ctx.targetMood = .active
            case "settingMoodEnergy:fun", "activity:road-trip", "mood:happy", "mood:party": ctx.targetMood = .fun
            case "settingDiversity:favorite": ctx.diversity = .favorite
            case "settingDiversity:discover": ctx.diversity = .discover
            case "settingDiversity:popular": ctx.diversity = .popular
            case "settingLanguage:without-words": ctx.blockedWave = true
            default:
                if seed.hasPrefix("artist:") {
                    let artist = String(seed.dropFirst("artist:".count))
                    if !artist.isEmpty { ctx.focusArtist = artist }
                } else if seed.contains("children") || seed.contains("podcast") || seed.contains("audiobook") {
                    ctx.blockedWave = true
                } else if seed.hasPrefix("mix-by-mood:") {
                    let part = String(seed.dropFirst("mix-by-mood:".count))
                    if part.contains("sad") { ctx.targetMood = .sad }
                    else if part.contains("calm") || part.contains("chill") { ctx.targetMood = .calm }
                    else if part.contains("fun") || part.contains("happy") { ctx.targetMood = .fun }
                    else if part.contains("active") || part.contains("energetic") { ctx.targetMood = .active }
                }
            }
        }
        ctx.centroid = AudioProfile.average(recentProfiles)
        return ctx
    }
}

final class AudioProfileStore {
    static let shared = AudioProfileStore()

    private static let file = "audio-profiles.json"
    private let lock = NSLock()
    private var profiles: [String: AudioProfile] = Storage.load(AudioProfileStore.file, as: [String: AudioProfile].self) ?? [:]
    private var failed: Set<String> = []
    private var busy = false

    func get(_ trackId: String) -> AudioProfile? {
        lock.lock()
        let cached = profiles[trackId]
        lock.unlock()
        return cached ?? Uncensor.shared.catalogAudioProfile(trackId)
    }

    func put(_ trackId: String, _ profile: AudioProfile) {
        lock.lock()
        failed.remove(trackId)
        profiles[trackId] = profile
        let snapshot = profiles
        lock.unlock()
        Storage.save(snapshot, Self.file)
    }

    func ensureAnalyzed(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        lock.lock()
        guard !busy else {
            lock.unlock()
            return
        }
        let need = Array(tracks.filter {
            profiles[$0.id] == nil && !failed.contains($0.id) && Uncensor.shared.catalogAudioProfile($0.id) == nil
        }.prefix(4))
        guard !need.isEmpty else {
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            defer {
                lock.lock()
                busy = false
                lock.unlock()
            }
            for track in need {
                let profile = await Self.resolveAndAnalyze(track: track)
                if let profile {
                    put(track.id, profile)
                } else {
                    lock.lock()
                    failed.insert(track.id)
                    lock.unlock()
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private static func resolveAndAnalyze(track: Track) async -> AudioProfile? {
        if let local = Uncensor.shared.localAudio(track.id) {
            return await analyzeAsset(url: local)
        }
        let downloadedURL = await MainActor.run { Downloads.shared.fileURL(for: track.id) }
        if let dl = downloadedURL {
            return await analyzeAsset(url: dl)
        }
        if let cachedUncensored = TrackFiles.existing(id: TrackFiles.Version.uncensored.cacheID(track.id), in: Storage.stream) {
            return await analyzeAsset(url: cachedUncensored)
        }
        if let cachedStream = TrackFiles.existing(id: track.id, in: Storage.stream) {
            return await analyzeAsset(url: cachedStream)
        }
        let isOffline = await MainActor.run { Connectivity.shared.offline || Settings.offlineMode }
        guard !isOffline else { return nil }
        guard let source = try? await TrackFiles.source(for: track, quality: Settings.streamQuality) else { return nil }
        if !source.needsFile, let url = source.urls.first {
            return await analyzeAsset(url: url, mime: source.mime)
        }
        let cacheID = source.version == .uncensored ? source.version.cacheID(track.id) : track.id
        if let downloaded = try? await TrackFiles.download(id: cacheID, from: source, to: Storage.stream) {
            return await analyzeAsset(url: downloaded)
        }
        return nil
    }

    static func analyzeAsset(url: URL, mime: String? = nil) async -> AudioProfile? {
        var options: [String: Any] = [:]
        if let mime, !url.isFileURL { options["AVURLAssetOutOfBandMIMETypeKey"] = mime }
        let asset = AVURLAsset(url: url, options: options.isEmpty ? nil : options)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)

        let descriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = Int(asbd?.mSampleRate ?? 44_100)
        let channels = Int(asbd?.mChannelsPerFrame ?? 2)
        let analyzer = StreamingAudioAnalyzer(channels: channels, sampleRate: rate)

        guard reader.startReading() else { return nil }
        let scale: Float = 1.0 / 32768.0
        while reader.status == .reading && !analyzer.isReady {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let ptr else { continue }
            let count = length / MemoryLayout<Int16>.stride
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                for i in 0..<count {
                    analyzer.pushSample(Float(samples[i]) * scale)
                    if analyzer.isReady { break }
                }
            }
        }
        if reader.status == .reading { reader.cancelReading() }
        return analyzer.finalizeProfile()
    }
}

/// Удалённые, каталожные и загруженные треки в «Моей волне» — по вкусу и настроению/звуку, как в Tune Native.
final class WaveTaste {
    static let shared = WaveTaste()

    private static let tasteMin = -10.0
    private static let tasteMax = 10.0
    private static let block = -3.0
    static let pass = 2.0
    private static let day = 24.0 * 3600
    private static let halfLife = 60.0
    private static let similarDays = 7.0
    private static let playedDays = 7.0
    private static let similarBatch = 3

    private struct Similar: Codable {
        var at: Double
        var ids: [String]
    }

    private struct Store: Codable {
        var taste: [String: [Double]] = [:]
        var artistNames: [String: [Double]] = [:]
        var tracks: [String: [Double]] = [:]
        var similar: [String: Similar] = [:]
        var played: [String: Double] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            taste = try c.decodeIfPresent([String: [Double]].self, forKey: .taste) ?? [:]
            artistNames = try c.decodeIfPresent([String: [Double]].self, forKey: .artistNames) ?? [:]
            tracks = try c.decodeIfPresent([String: [Double]].self, forKey: .tracks) ?? [:]
            similar = try c.decodeIfPresent([String: Similar].self, forKey: .similar) ?? [:]
            played = try c.decodeIfPresent([String: Double].self, forKey: .played) ?? [:]
        }
    }

    private static let file = "wave-taste.json"
    private let lock = NSLock()
    private var store = Storage.load(WaveTaste.file, as: Store.self) ?? Store()
    private var similarBusy = false

    private static var now: Double { Date().timeIntervalSince1970 }

    static func normName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }

    private func save() {
        Storage.save(store, Self.file)
    }

    private func decayed(_ entry: [Double]?, at: Double) -> Double {
        guard let entry, entry.count == 2 else { return 0 }
        return entry[0] * pow(0.5, max(0, at - entry[1]) / (Self.halfLife * Self.day))
    }

    private func tasteOf(_ id: String, at: Double) -> Double {
        decayed(store.taste[id], at: at)
    }

    static func delta(_ kind: String, played: Double?, length: Double) -> Double {
        switch kind {
        case "trackFinished":
            return length <= 0 || (played ?? length) / length >= 0.7 ? 1 : 0
        case "skip":
            return (played.map { $0 < 30 } ?? false) ? -1 : 0
        case "like": return 3
        case "unlike": return -3
        case "dislike": return -5
        case "undislike": return 5
        default: return 0
        }
    }

    static func trackDelta(_ kind: String, played: Double?, length: Double) -> Double {
        switch kind {
        case "trackFinished":
            return length <= 0 || (played ?? length) / length >= 0.7 ? 1.5 : 0
        case "skip":
            return (played.map { $0 < 30 } ?? false) ? -2 : 0
        case "like": return 4
        case "unlike": return -3
        case "dislike": return -8
        case "undislike": return 5
        default: return 0
        }
    }

    /// Реакция пользователя: обновляет вкус по ID артиста, имени артиста и самому треку.
    func react(_ kind: String, track: Track, played: Double?) {
        let aChange = Self.delta(kind, played: played, length: track.duration)
        let tChange = Self.trackDelta(kind, played: played, length: track.duration)
        guard aChange != 0 || tChange != 0 else { return }
        let artists = track.artistList.map(\.id).filter { !$0.isEmpty && !TuneCatalogID.isSyntheticArtist($0) }
        let names = track.artistList.map { Self.normName($0.name) }.filter { !$0.isEmpty }
        lock.lock()
        defer { lock.unlock() }
        let at = Self.now
        if aChange != 0 {
            for artist in artists {
                let score = min(max(decayed(store.taste[artist], at: at) + aChange, Self.tasteMin), Self.tasteMax)
                store.taste[artist] = [score, at]
            }
            for name in names {
                let score = min(max(decayed(store.artistNames[name], at: at) + aChange, Self.tasteMin), Self.tasteMax)
                store.artistNames[name] = [score, at]
            }
        }
        if tChange != 0 && !track.id.isEmpty {
            let score = min(max(decayed(store.tracks[track.id], at: at) + tChange, Self.tasteMin), Self.tasteMax)
            store.tracks[track.id] = [score, at]
        }
        save()
    }

    func likedArtists() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let at = Self.now
        return store.taste.keys
            .map { ($0, tasteOf($0, at: at)) }
            .filter { $0.1 >= 1 }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .map(\.0)
    }

    func loadSimilar(_ seeds: [String]) {
        lock.lock()
        let at = Self.now
        let need = Array(seeds.filter { id in
            guard !id.isEmpty, !TuneCatalogID.isSyntheticArtist(id) else { return false }
            guard let entry = store.similar[id] else { return true }
            return at - entry.at > Self.similarDays * Self.day
        }.prefix(Self.similarBatch))
        if need.isEmpty || similarBusy {
            lock.unlock()
            return
        }
        similarBusy = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            for id in need {
                guard let ids = try? await API.shared.similarArtistIds(id) else { continue }
                lock.lock()
                store.similar[id] = Similar(at: Self.now, ids: ids)
                save()
                lock.unlock()
            }
            lock.lock()
            similarBusy = false
            lock.unlock()
        }
    }

    func played(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = store.played[id] else { return false }
        return Self.now - at < Self.playedDays * Self.day
    }

    func markPlayed(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        let at = Self.now
        store.played = store.played.filter { at - $0.value < Self.playedDays * Self.day }
        store.played[id] = at
        save()
    }

    func scoreWaveCandidate(
        track: Track,
        likedTrack: Bool,
        inHistory: Bool,
        isUGC: Bool,
        profile: AudioProfile?,
        context: WaveContext,
        recentArtists: Set<String>,
        recentArtistNames: Set<String>,
        liked: [String]
    ) -> Double? {
        if context.blockedWave { return nil }
        if context.diversity == .favorite && !likedTrack && !inHistory { return nil }
        if context.diversity == .discover && (likedTrack || inHistory) { return nil }

        let artistIDs = track.artistList.map(\.id).filter { !$0.isEmpty }
        let normNames = track.artistList.map { Self.normName($0.name) }.filter { !$0.isEmpty }

        lock.lock()
        defer { lock.unlock() }

        if let focus = context.focusArtist {
            let direct = artistIDs.contains(focus)
            let sim = store.similar[focus]?.ids.contains(where: artistIDs.contains) == true
            if !direct && !sim { return nil }
        }

        let at = Self.now
        let trTaste = decayed(store.tracks[track.id], at: at)
        if trTaste <= Self.block { return nil }

        let idTastes = artistIDs.map { tasteOf($0, at: at) }
        if idTastes.contains(where: { $0 <= Self.block }) { return nil }

        let nameTastes = normNames.map { decayed(store.artistNames[$0], at: at) }
        if nameTastes.contains(where: { $0 <= Self.block }) { return nil }

        var moodBonus = 0.0
        if let target = context.targetMood {
            guard let p = profile else { return nil }
            switch target {
            case .sad, .calm:
                if p.bass > 0.52 || p.energy > 0.58 || p.pulse > 0.68 { return nil }
            case .active:
                if p.energy < 0.35 { return nil }
            case .fun:
                if p.energy < 0.25 { return nil }
            }
            let aff = p.moodAffinity(target)
            if aff < 0.45 { return nil }
            moodBonus += Double(aff - 0.45) * 4.0
        }
        if let centroid = context.centroid {
            if let p = profile {
                let dist = p.distance(to: centroid)
                if dist > 0.46 || (centroid.bass < 0.38 && p.bass > 0.62) || (centroid.energy < 0.40 && p.energy > 0.70) {
                    return nil
                }
                moodBonus += Double(min(1, max(0, 1 - dist / 0.46))) * 1.5
            } else if centroid.energy < 0.42 && centroid.bass < 0.42 {
                return nil
            }
        }

        var score = 0.0
        if likedTrack { score += 2.0 }
        if inHistory { score += 1.0 }
        if isUGC && likedTrack && context.targetMood == nil && context.centroid == nil {
            score += 0.5
        }
        score += min(max(trTaste, -3), 3)

        if artistIDs.contains(where: recentArtists.contains) || normNames.contains(where: recentArtistNames.contains) {
            score += 2.0
        }
        let bestArtistTaste = max(idTastes.max() ?? -.infinity, nameTastes.max() ?? -.infinity)
        if bestArtistTaste.isFinite {
            score += min(max(bestArtistTaste, -2), 3)
        }

        func similarTo(_ seed: String) -> Bool {
            guard let list = store.similar[seed] else { return false }
            return artistIDs.contains(where: list.ids.contains)
        }
        let simScore = Double(liked.filter(similarTo).count) * 2 + Double(recentArtists.filter(similarTo).count)
        return score + min(simScore, 2) + moodBonus
    }

    static func pickWeighted(_ scores: [Double], random: Double) -> Int? {
        let total = scores.reduce(0, +)
        guard !scores.isEmpty, total > 0 else { return nil }
        var at = min(max(random, 0), 0.999999) * total
        for (index, score) in scores.enumerated() {
            at -= score
            if at < 0 { return index }
        }
        return scores.count - 1
    }
}

