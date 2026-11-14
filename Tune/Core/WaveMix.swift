import Foundation

/// Что Tune сам подмешивает в «Мою волну», как в Tune Native: свои загруженные треки из
/// «Мне нравится» и удалённые Яндексом треки, которые вернул «Без цензуры», — по вкусу.
@MainActor
final class WaveMix {
    static let shared = WaveMix()

    /// Свой трек попадает в новую пачку с такой вероятностью, %.
    private static let ownChance = 25
    /// Свои треки перечитываются раз в полчаса.
    private static let ownTTL: TimeInterval = 30 * 60
    /// Какие треки списка удалены — раз в сутки.
    private static let restoredTTL: TimeInterval = 24 * 3600
    private static let chunk = 200
    /// Исполнители скольких последних треков волны считаются «звучавшими».
    private static let recentCount = 30

    private var own: [Track] = []
    private var ownAt: Date?
    private var ownUsed: Set<String> = []
    private var ownLast = false

    private var restored: [Track] = []
    private var restoredAt: Date?
    private var restoredGap = WaveMix.gap()

    /// Через сколько треков волны может встать следующий удалённый: от 10 до 15.
    private static func gap() -> Int { Int.random(in: 10...15) }

    /// Новая волна: повторы и промежутки считаются заново.
    func started() {
        ownUsed = []
        ownLast = false
        restoredGap = Self.gap()
    }

    /// Перед новой пачкой: свои и удалённые треки подгружаются в фоне, если пора.
    func refill(queue: [Track]) {
        loadOwn()
        loadRestored(queue: queue)
    }

    /// Трек, который встанет в начало новой пачки: удалённый по вкусу, иначе иногда — свой.
    func pick(known: Set<String>, count: Int, queue: [Track]) -> Track? {
        if let track = pickRestored(known: known, count: count, queue: queue) { return track }
        return pickOwn(known: known)
    }

    // MARK: - Свои треки

    private func pickOwn(known: Set<String>) -> Track? {
        guard Settings.ownInWave else { return nil }
        if ownLast {
            // Не две пачки подряд.
            ownLast = false
            return nil
        }
        guard Int.random(in: 0..<100) < Self.ownChance else { return nil }
        let pool = own.filter { !ownUsed.contains($0.id) && !known.contains($0.id) }
        guard var track = pool.randomElement() else { return nil }
        ownUsed.insert(track.id)
        ownLast = true
        track.batch = nil
        return track
    }

    /// Свои загруженные треки из «Мне нравится»: у них номер не из одних цифр.
    private func loadOwn() {
        guard Settings.ownInWave else { return }
        if let ownAt, Date().timeIntervalSince(ownAt) < Self.ownTTL { return }
        ownAt = Date()
        let ids = Session.shared.likedIds.filter { !$0.allSatisfy(\.isNumber) }
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
            self.own = found.filter { !$0.unavailable }
        }
    }

    // MARK: - Удалённые треки

    private func recentArtists(_ queue: [Track]) -> Set<String> {
        Set(queue.suffix(Self.recentCount).flatMap { $0.artistList.map(\.id) }.filter { !$0.isEmpty })
    }

    private func pickRestored(known: Set<String>, count: Int, queue: [Track]) -> Track? {
        guard Settings.restoredInWave, Settings.uncensor, !restored.isEmpty else { return nil }
        restoredGap = max(restoredGap - count, 0)
        guard restoredGap == 0 else { return nil }
        let recent = recentArtists(queue)
        let liked = WaveTaste.shared.likedArtists()
        let session = Session.shared
        let candidates: [(Track, Double)] = restored.compactMap { track in
            guard !known.contains(track.id), !session.disliked.contains(track.id), Uncensor.shared.has(track.id),
                  !WaveTaste.shared.played(track.id) else { return nil }
            let artists = track.artistList.map(\.id).filter { !$0.isEmpty }
            guard let score = WaveTaste.shared.score(artists: artists, likedTrack: session.isLiked(track.id), recent: recent, liked: liked),
                  score >= WaveTaste.pass else { return nil }
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

    /// Удалённые треки с версией без цензуры: какие из треков списка FckCensor Яндекс закрыл.
    /// Раз в сутки, в фоне; похожие исполнители для оценки подгружаются заодно.
    private func loadRestored(queue: [Track]) {
        guard Settings.restoredInWave, Settings.uncensor else { return }
        WaveTaste.shared.loadSimilar(WaveTaste.shared.likedArtists() + Array(recentArtists(queue)))
        if let restoredAt, Date().timeIntervalSince(restoredAt) < Self.restoredTTL { return }
        let listed = Uncensor.shared.fileIds()
        guard !listed.isEmpty else { return }
        restoredAt = Date()
        Task {
            do {
                // Какие из треков списка удалены, помнится на диске сутки.
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
            } catch {
                Log.shared.add("удалённые треки для волны: \(error.localizedDescription)")
                // Повтор через час, а не через сутки.
                self.restoredAt = Date().addingTimeInterval(-Self.restoredTTL + 3600)
            }
        }
    }
}
