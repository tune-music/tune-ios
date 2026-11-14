import Foundation

/// Удалённые треки в «Моей волне» — по вкусу, как в Tune Native. Рекомендации Яндекса
/// считаются на его серверах и треков, которые он удалил, не знают. Tune оценивает их сам,
/// по исполнителям: кого ставит текущая волна, кто на них похож (`artists/<id>/similar`) и
/// как человек реагирует в волне. Всё хранится только на этом устройстве.
final class WaveTaste {
    static let shared = WaveTaste()

    private static let tasteMin = -10.0
    private static let tasteMax = 10.0
    /// Исполнитель с такой оценкой в волну не попадает.
    private static let block = -3.0
    /// Меньше — трек не подмешиваем.
    static let pass = 2.0
    private static let day = 24.0 * 3600
    /// Старые реакции забываются: половина оценки за столько дней.
    private static let halfLife = 60.0
    /// Похожие исполнители перечитываются раз в неделю.
    private static let similarDays = 7.0
    /// Сыгранный удалённый трек не повторяется неделю, и после перезапуска тоже.
    private static let playedDays = 7.0
    /// Сколько похожих запрашивать за раз: волна их не ждёт, они нужны следующим пачкам.
    private static let similarBatch = 3

    private struct Similar: Codable {
        var at: Double
        var ids: [String]
    }

    private struct Store: Codable {
        /// Исполнитель → оценка и когда она менялась.
        var taste: [String: [Double]] = [:]
        var similar: [String: Similar] = [:]
        var played: [String: Double] = [:]
    }

    private static let file = "wave-taste.json"
    private let lock = NSLock()
    private var store = Storage.load(WaveTaste.file, as: Store.self) ?? Store()
    private var similarBusy = false

    private static var now: Double { Date().timeIntervalSince1970 }

    private func save() {
        Storage.save(store, Self.file)
    }

    private func tasteOf(_ id: String, at: Double) -> Double {
        guard let entry = store.taste[id], entry.count == 2 else { return 0 }
        return entry[0] * pow(0.5, max(0, at - entry[1]) / (Self.halfLife * Self.day))
    }

    /// Сколько событие волны добавляет оценке исполнителя.
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

    /// Реакция в волне: оценки исполнителей трека меняются и сохраняются.
    func react(_ kind: String, track: Track, played: Double?) {
        let change = Self.delta(kind, played: played, length: track.duration)
        let artists = track.artistList.map(\.id).filter { !$0.isEmpty }
        guard change != 0, !artists.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let at = Self.now
        for artist in artists {
            let score = min(max(tasteOf(artist, at: at) + change, Self.tasteMin), Self.tasteMax)
            store.taste[artist] = [score, at]
        }
        save()
    }

    /// Любимые исполнители волны: с оценкой от единицы, двадцать лучших.
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

    /// Подгружает похожих исполнителей в фоне, понемногу. Ошибка не важна: повторится позже.
    func loadSimilar(_ seeds: [String]) {
        lock.lock()
        let at = Self.now
        let need = Array(seeds.filter { id in
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

    /// Удалённый трек уже был в волне на этой неделе.
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

    /// Оценка трека по его исполнителям; nil — в волну он не годится совсем.
    /// recent — исполнители последних треков волны, liked — любимые исполнители волны.
    func score(artists: [String], likedTrack: Bool, recent: Set<String>, liked: [String]) -> Double? {
        guard !artists.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let at = Self.now
        let tastes = artists.map { tasteOf($0, at: at) }
        if tastes.contains(where: { $0 <= Self.block }) { return nil }
        var score = likedTrack ? 2.0 : 0
        if artists.contains(where: recent.contains) { score += 2 }
        score += min(max(tastes.max() ?? 0, -2), 3)
        // Похожий на исполнителя, которого дослушивают, — сильный довод; на исполнителя из волны —
        // слабый: одного такого совпадения мало, нужны два.
        func similarTo(_ seed: String) -> Bool {
            guard let list = store.similar[seed] else { return false }
            return artists.contains(where: list.ids.contains)
        }
        let similar = Double(liked.filter(similarTo).count) * 2 + Double(recent.filter(similarTo).count)
        return score + min(similar, 2)
    }

    /// Случайный выбор с весом по оценке. random — от 0 до 1.
    static func pickWeighted(_ scores: [Double], random: Double) -> Int? {
        let total = scores.reduce(0, +)
        guard !scores.isEmpty, total > 0 else { return nil }
        var at = random * total
        for (index, score) in scores.enumerated() {
            at -= score
            if at < 0 { return index }
        }
        return scores.count - 1
    }
}
