import Foundation

/// Демо-режим для снимков экрана: `-demo -screen home`. Приложение открывается без входа
/// и показывает данные из demo.json вместо запросов к Яндексу.
enum Demo {
    static let on = ProcessInfo.processInfo.arguments.contains("-demo")

    /// Какой экран открыть сразу: home, search, library, likes, album, artist, player, settings.
    static var screen: String {
        on ? (UserDefaults.standard.string(forKey: "screen") ?? "home") : ""
    }

    struct Fixture: Decodable {
        var tracks: [Track] = []
        var albums: [Card] = []
        var artists: [Card] = []
        var releases: [Card] = []
        var waves: [WaveCard] = []
        var personal: [Playlist] = []
        var playlists: [Playlist] = []
    }

    static let data: Fixture = {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: bytes)
        else { return Fixture() }
        return fixture
    }()

    static var home: [HomeBlock] {
        [
            HomeBlock(id: "releases", title: "Новые релизы", items: data.releases.map { .album($0) }),
            HomeBlock(id: "personal", title: "Собрано для вас", items: data.personal.map { .playlist($0) }),
            HomeBlock(id: "artists", title: "В стиле", items: data.artists.map { .artist($0) }),
            HomeBlock(id: "albums", title: "Популярные альбомы", items: data.albums.map { .album($0) }),
        ]
    }

    static let podcasts = [Card(id: "demo-podcast", title: "Как устроена музыка", subtitle: "Подкаст", cover: nil)]

    static func search(types: String, filter: String?, page: Int, size: Int) -> SearchResult {
        let types = Set(types.split(separator: ","))
        let size = types.count == 1 ? min(size, 8) : size
        func slice<T>(_ items: [T]) -> [T] {
            Array(items.dropFirst(page * size).prefix(size))
        }
        if filter == "podcast" {
            var episode = data.tracks.first
            episode?.title = "Почему припев запоминается"
            return page == 0 ? SearchResult(podcasts: podcasts, episodes: episode.map { [$0] } ?? []) : SearchResult()
        }
        let tracks = types.contains("track") ? data.tracks : []
        let albums = types.contains("album") ? data.albums : []
        let artists = types.contains("artist") ? data.artists : []
        let playlists = types.contains("playlist") ? data.playlists : []
        return SearchResult(
            best: types.count > 1 ? artists.first.map { .artist($0) } : nil,
            tracks: slice(tracks), albums: slice(albums), artists: slice(artists), playlists: slice(playlists),
            podcasts: types.contains("podcast") ? slice(podcasts) : [],
            hasMore: [tracks.count, albums.count, artists.count, playlists.count].contains { $0 > (page + 1) * size }
        )
    }

    static let lyrics: [LyricLine] = (0..<24).map { index in
        LyricLine(id: index, time: Double(index) * 6, text: ["Первая строка песни", "И вторая, чуть длиннее первой", "Здесь звучит припев", "И ещё одна строка"][index % 4])
    }
}

/// Журнал ошибок: его можно скопировать из настроек и прислать разработчику.
final class Log {
    static let shared = Log()

    private let lock = NSLock()
    private var lines: [String] = []
    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func add(_ text: String) {
        lock.lock()
        lines.append("\(stamp.string(from: Date())) \(text)")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
