import Foundation

/// Что Tune сам подмешивает в волну, как в Tune Native: свои загруженные треки (с учётом
/// настроения, звука и вкуса), удалённые Яндексом треки («Без цензуры») и треки из «Каталога Tune».
@MainActor
final class WaveMix {
    static let shared = WaveMix()

    private static let ownChance = 25
    private static let ownTTL: TimeInterval = 30 * 60
    private static let restoredTTL: TimeInterval = 24 * 3600
    private static let chunk = 200
    private static let recentCount = 30

    private var own: [Track] = []
    private var ownAt: Date?
    private var ownUsed: Set<String> = []
    private var ownLast = false

    private var restored: [Track] = []
    private var restoredAt: Date?
    private var restoredGap = WaveMix.gap()
    private var catalogPool: [Track] = []

    private static func gap() -> Int { Int.random(in: 10...15) }

    func started() {
        ownUsed = []
        ownLast = false
        restoredGap = Self.gap()
    }

    func refill(queue: [Track], seeds: [String] = []) {
        loadOwn()
        loadRestored(queue: queue, seeds: seeds)
    }

    func pick(known: Set<String>, count: Int, queue: [Track], seeds: [String] = []) -> Track? {
        let context = makeContext(queue: queue, seeds: seeds)
        if context.blockedWave { return nil }
        if let track = pickRestored(known: known, count: count, queue: queue, context: context) { return track }
        return pickOwn(known: known, queue: queue, context: context)
    }

    private func makeContext(queue: [Track], seeds: [String]) -> WaveContext {
        let activeSeeds = seeds.isEmpty ? ["user:onyourwave"] : seeds
        let recentProfiles = queue.suffix(12).compactMap { AudioProfileStore.shared.get($0.id) }
        return WaveContext.fromSeeds(activeSeeds, recentProfiles: recentProfiles)
    }

    private func recentHistoryIDs() -> Set<String> {
        var ids = Set(Stats.shared.plays.suffix(500).map(\.id))
        for entry in CatalogLibraryStore.shared.historyEntries {
            ids.insert(entry.id)
        }
        return ids
    }

    private func recentArtistInfo(_ queue: [Track]) -> (ids: Set<String>, names: Set<String>) {
        let tail = queue.suffix(Self.recentCount)
        let ids = Set(tail.flatMap { $0.artistList.map(\.id) }.filter { !$0.isEmpty })
        let names = Set(tail.flatMap { $0.artistList.map { WaveTaste.normName($0.name) } }.filter { !$0.isEmpty })
        return (ids, names)
    }

    // MARK: - Свои треки

    private func pickOwn(known: Set<String>, queue: [Track], context: WaveContext) -> Track? {
        guard Settings.ownInWave else { return nil }
        if ownLast {
            ownLast = false
            return nil
        }
        guard Int.random(in: 0..<100) < Self.ownChance else { return nil }
        let session = Session.shared
        let historyIDs = recentHistoryIDs()
        let recent = recentArtistInfo(queue)
        let likedArtists = WaveTaste.shared.likedArtists()
        let candidates: [(Track, Double)] = own.compactMap { track in
            guard !ownUsed.contains(track.id), !known.contains(track.id), !session.disliked.contains(track.id) else {
                return nil
            }
            guard let score = WaveTaste.shared.scoreWaveCandidate(
                track: track,
                likedTrack: session.isLiked(track.id),
                inHistory: historyIDs.contains(track.id),
                isUGC: true,
                profile: AudioProfileStore.shared.get(track.id),
                context: context,
                recentArtists: recent.ids,
                recentArtistNames: recent.names,
                liked: likedArtists
            ), score >= 1.0 else { return nil }
            return (track, score)
        }
        guard let at = WaveTaste.pickWeighted(candidates.map(\.1), random: Double.random(in: 0..<1)) else { return nil }
        var track = candidates[at].0
        ownUsed.insert(track.id)
        ownLast = true
        track.batch = nil
        return track
    }

    private func loadOwn() {
        guard Settings.ownInWave else { return }
        if let ownAt, Date().timeIntervalSince(ownAt) < Self.ownTTL { return }
        ownAt = Date()
        let historyIDs = recentHistoryIDs()
        var seen = Set<String>()
        let ids = (Session.shared.likedIds + Array(historyIDs)).filter {
            !$0.isEmpty && !$0.allSatisfy(\.isNumber) && !TuneCatalogID.isSyntheticTrack($0) && seen.insert($0).inserted
        }
        guard !ids.isEmpty else {
            own = []
            return
        }
        Task {
            var found: [Track] = []
            for start in stride(from: 0, to: ids.count, by: Self.chunk) {
                guard let part = try? await API.shared.tracks(ids: Array(ids[start..<min(start + Self.chunk, ids.count)])) else {
                    Log.shared.add("свои треки для волны: не загрузились")
                    self.ownAt = nil
                    return
                }
                found += part
            }
            let valid = found.filter { !$0.unavailable }
            self.own = valid
            AudioProfileStore.shared.ensureAnalyzed(valid)
        }
    }

    // MARK: - Удалённые и каталожные треки

    private func pickRestored(known: Set<String>, count: Int, queue: [Track], context: WaveContext) -> Track? {
        guard Settings.restoredInWave, Settings.uncensor || Settings.catalog else { return nil }
        let pool = restored + (Settings.catalog ? catalogPool : [])
        guard !pool.isEmpty else { return nil }
        restoredGap = max(restoredGap - count, 0)
        guard restoredGap == 0 else { return nil }
        let recent = recentArtistInfo(queue)
        let likedArtists = WaveTaste.shared.likedArtists()
        let historyIDs = recentHistoryIDs()
        let session = Session.shared
        let candidates: [(Track, Double)] = pool.compactMap { track in
            let isSynthetic = TuneCatalogID.isSyntheticTrack(track.id)
            if isSynthetic && !Settings.catalog { return nil }
            guard !known.contains(track.id), !session.disliked.contains(track.id), Uncensor.shared.hasAudio(track.id),
                  !WaveTaste.shared.played(track.id) else { return nil }
            guard let score = WaveTaste.shared.scoreWaveCandidate(
                track: track,
                likedTrack: session.isLiked(track.id),
                inHistory: historyIDs.contains(track.id),
                isUGC: false,
                profile: AudioProfileStore.shared.get(track.id),
                context: context,
                recentArtists: recent.ids,
                recentArtistNames: recent.names,
                liked: likedArtists
            ), score >= WaveTaste.pass else { return nil }
            return (track, score)
        }
        guard let at = WaveTaste.pickWeighted(candidates.map(\.1), random: Double.random(in: 0..<1)) else { return nil }
        var track = candidates[at].0
        restoredGap = Self.gap()
        WaveTaste.shared.markPlayed(track.id)
        track.batch = nil
        return track
    }

    private struct RestoredCache: Codable {
        var at: Date
        var listed: Int
        var ids: [String]
    }

    private func loadRestored(queue: [Track], seeds: [String]) {
        guard Settings.restoredInWave, Settings.uncensor || Settings.catalog else { return }
        if Settings.catalog {
            catalogPool = Uncensor.shared.catalogWaveTrackIds().compactMap { id in
                Uncensor.shared.catalogTrack(id).flatMap(API.parseTrack)
            }
        } else {
            catalogPool = []
        }
        let recent = recentArtistInfo(queue)
        let focusSeeds = seeds.compactMap { $0.hasPrefix("artist:") ? String($0.dropFirst("artist:".count)) : nil }
        WaveTaste.shared.loadSimilar(focusSeeds + WaveTaste.shared.likedArtists() + Array(recent.ids))
        guard Settings.uncensor else { return }
        if let restoredAt, Date().timeIntervalSince(restoredAt) < Self.restoredTTL { return }
        let listed = Uncensor.shared.fileIds()
        guard !listed.isEmpty else { return }
        restoredAt = Date()
        Task {
            do {
                var gone: [String]
                if let cache = Storage.load("restored.json", as: RestoredCache.self),
                   Date().timeIntervalSince(cache.at) < Self.restoredTTL, cache.listed == listed.count {
                    let set = Set(listed)
                    gone = cache.ids.filter(set.contains)
                } else {
                    gone = []
                    for start in stride(from: 0, to: listed.count, by: Self.chunk) {
                        gone += try await API.shared.unavailableIds(Array(listed[start..<min(start + Self.chunk, listed.count)]))
                    }
                    Storage.save(RestoredCache(at: Date(), listed: listed.count, ids: gone), "restored.json")
                }
                var tracks: [Track] = []
                for start in stride(from: 0, to: gone.count, by: Self.chunk) {
                    tracks += try await API.shared.tracks(ids: Array(gone[start..<min(start + Self.chunk, gone.count)]))
                }
                self.restored = tracks
                AudioProfileStore.shared.ensureAnalyzed(tracks)
            } catch {
                Log.shared.add("удалённые треки для волны: \(error.localizedDescription)")
                self.restoredAt = Date().addingTimeInterval(-Self.restoredTTL + 3600)
            }
        }
    }
}

