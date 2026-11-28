import Foundation

/// Ответ API без жёсткой схемы: у Яндекса одно и то же поле бывает строкой и числом.
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = (raw is NSNull) ? nil : raw
    }

    static func parse(_ data: Data) -> JSON {
        JSON(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let list = raw as? [Any], index >= 0, index < list.count else { return JSON(nil) }
        return JSON(list[index])
    }

    var exists: Bool { raw != nil }
    var isObject: Bool { raw is [String: Any] }
    var isArray: Bool { raw is [Any] }
    var dict: [String: Any]? { raw as? [String: Any] }
    var array: [JSON] { (raw as? [Any])?.map { JSON($0) } ?? [] }
    var string: String? { raw as? String }
    var bool: Bool? { raw as? Bool }
    var int: Int? { (raw as? NSNumber)?.intValue }
    var int64: Int64? { (raw as? NSNumber)?.int64Value }
    var double: Double? { (raw as? NSNumber)?.doubleValue }

    /// Номер трека, альбома или исполнителя: строкой или числом.
    var idText: String? {
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Текст песни: строки, авторы и откуда он взят.
struct LyricsText: Codable {
    var lines: [LyricLine]
    var authors: [String]?
    /// «Яндекс Музыка», «LRCLIB» или «NetEase».
    var source: String?
    /// С какими настройками искали: поменялись — ищем заново.
    var searched: String?

    static let yandex = "Яндекс Музыка"
    var synced: Bool { lines.contains { $0.time != nil } }
}

struct ArtistRef: Codable, Hashable {
    var id: String
    var name: String
}

/// Где трек нарастает в начале и затихает в конце, секунды от начала трека.
struct FadePoints: Codable, Hashable {
    var inStart: Double
    var inStop: Double
    var outStart: Double
    var outStop: Double

    static func parse(_ value: JSON) -> FadePoints? {
        func point(_ key: String) -> Double? {
            guard let x = value[key].double, x.isFinite, x >= 0 else { return nil }
            return x
        }
        guard let inStart = point("inStart"), let inStop = point("inStop"), let outStart = point("outStart"), let outStop = point("outStop"),
              inStop >= inStart, outStop > outStart else { return nil }
        return FadePoints(inStart: inStart, inStop: inStop, outStart: outStart, outStop: outStop)
    }
}

struct Track: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var version: String?
    var artists: String
    var artistList: [ArtistRef]
    var durationMs: Int
    var cover: String?
    var albumId: String?
    var albumTitle: String
    var explicit: Bool
    var hasLyrics: Bool
    /// Яндекс не даёт слушать: нет прав или трек убран.
    var unavailable: Bool
    /// Играет версия без цензуры из списка FckCensor.
    var uncensored: Bool
    /// Пачка волны, из которой пришёл трек.
    var batch: String?
    /// Средняя громкость записи в LUFS, как её измерил Яндекс. По ней выравнивается звук.
    var loudness: Double?
    /// Истинный пик записи в dBTP: тихий трек поднимается не выше, чем он позволяет.
    var peak: Double?
    /// Точки плавного перехода в секундах, которые Яндекс размечает для музыки.
    var fade: FadePoints?
    /// Точки перехода для волны-сета: в ней треки сведены плотнее, чем обычно.
    var mixFade: FadePoints?
    /// Загружен самим пользователем: слушать его может только он.
    var ugc: Bool?
    /// Дата добавления в список, если Яндекс её прислал.
    var addedAt: Date? = nil
    /// Доступность файла Яндекса до подмены из каталога «Без цензуры».
    var yandexAvailable: Bool? = nil
    /// Аудиофайл берётся из дополнительного каталога Tune.
    var catalog: Bool? = nil

    var isCatalog: Bool { catalog == true }

    /// Свой загруженный трек. Яндекс отмечает его полем trackSource, а у треков, сохранённых
    /// прошлыми версиями, этого поля нет — тогда узнаём по номеру: он не из одних цифр.
    var isPrivate: Bool {
        ugc ?? !id.allSatisfy(\.isNumber)
    }

    func withUploadedMetadata(title: String, artist: String) -> Track {
        var track = self
        track.title = title
        track.version = nil
        track.artists = artist
        track.artistList = artist.isEmpty ? [] : [ArtistRef(id: "", name: artist)]
        return track
    }

    var duration: Double { Double(durationMs) / 1000 }

    /// Так трек называют волна и отчёты: id:альбом.
    var fullId: String {
        albumId.map { "\(id):\($0)" } ?? id
    }

    var shareURL: URL? {
        if TuneCatalogID.isSyntheticTrack(id) { return nil }
        if let albumId, !TuneCatalogID.isSyntheticAlbum(albumId) {
            return URL(string: "https://music.yandex.ru/album/\(albumId)/track/\(id)")
        }
        return URL(string: "https://music.yandex.ru/track/\(id)")
    }

    var fullTitle: String {
        guard let version, !version.isEmpty else { return title }
        return "\(title) (\(version))"
    }
}

struct Playlist: Codable, Hashable, Identifiable {
    var owner: String
    var kind: String
    var title: String
    var count: Int
    var cover: String?
    var description: String? = nil
    var customCover: Bool? = nil

    var id: String { "\(owner):\(kind)" }

    var shareURL: URL? {
        if owner == TuneCatalogID.owner { return nil }
        return URL(string: "https://music.yandex.ru/users/\(owner)/playlists/\(kind)")
    }
}

enum TuneCatalogID {
    static let owner = "tune-catalog"
    static let syntheticTrackBase: Int64 = 9_000_000_000
    static let syntheticAlbumBase: Int64 = 900_000_000
    static let syntheticArtistBase: Int64 = 90_000_000
    static let syntheticPlaylistBase: Int64 = 9_000_000

    static func isNumeric(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func isSyntheticTrack(_ id: String) -> Bool {
        guard isNumeric(id), let value = Int64(id) else { return false }
        return value > syntheticTrackBase
    }

    static func isSyntheticAlbum(_ id: String) -> Bool {
        guard isNumeric(id), let value = Int64(id) else { return false }
        return value > syntheticAlbumBase && value < syntheticTrackBase
    }

    static func isSyntheticArtist(_ id: String) -> Bool {
        guard isNumeric(id), let value = Int64(id) else { return false }
        return value > syntheticArtistBase && value < syntheticAlbumBase
    }

    static func isSyntheticPlaylist(_ id: String) -> Bool {
        guard isNumeric(id), let value = Int64(id) else { return false }
        return value > syntheticPlaylistBase && value < syntheticArtistBase
    }
}

/// Плейлист целиком: треки и то, что показывается в шапке.
struct PlaylistPage {
    var tracks: [Track] = []
    var author = ""
    var about = ""
    /// Название и обложка: нужны, когда плейлист открыт по ссылке и о нём ничего не известно.
    var title = ""
    var cover: String?
    /// Открыт ли плейлист другим людям. Неизвестно, пока страница не загружена.
    var open: Bool?
}

/// «58 мин», «2 ч 5 мин»: общая длительность списка.
func lengthText(_ tracks: [Track]) -> String {
    let minutes = Int(tracks.reduce(0) { $0 + $1.duration } / 60)
    return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
}

/// Время прослушивания в топе месяца: до 45 минут — минуты, дальше — часы с шагом 0,5.
func topListenTimeText(_ seconds: Double) -> String? {
    guard seconds.isFinite, seconds > 0 else { return nil }
    let minutes = seconds / 60
    if minutes <= 45 {
        let rounded = Int(minutes.rounded())
        return rounded > 0 ? "\(rounded) мин" : nil
    }
    let halfHours = Int((minutes / 60 * 2).rounded())
    return halfHours.isMultiple(of: 2) ? "\(halfHours / 2) ч" : "\(halfHours / 2),5 ч"
}

/// Карточка альбома или исполнителя.
struct Card: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var cover: String?
    var kind: String? = nil
}

/// Волна по жанру, настроению или занятию.
struct WaveCard: Codable, Hashable, Identifiable {
    var title: String
    var seeds: [String]
    var cover: String?
    var color: String?

    var id: String { seeds.joined(separator: ",") }
}

/// Карточка на полке главной.
enum HomeItem: Hashable, Identifiable, Codable {
    case album(Card)
    case artist(Card)
    case playlist(Playlist)
    case wave(WaveCard)

    var id: String {
        switch self {
        case .album(let card): return "album:\(card.id)"
        case .artist(let card): return "artist:\(card.id)"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        case .wave(let wave): return "wave:\(wave.id)"
        }
    }
}

/// Полка главной: название и карточки.
struct HomeBlock: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var items: [HomeItem]
}

struct HomePage: Codable {
    var waves: [WaveCard] = []
    var blocks: [HomeBlock] = []
    var recent: [Track]? = nil
    var trends: [HomeBlock]? = nil
}

struct Profile: Codable {
    var uid: String
    var name: String
    var login: String
    var plus: Bool
}

struct AlbumPage: Codable {
    var card: Card
    var year: Int?
    var tracks: [Track]
    var artist: ArtistRef?
    var label = ""
    var genre = ""
    /// single, compilation, podcast; у обычного альбома пусто.
    var kind = ""
    /// Сколько треков на каждом диске.
    var disks: [Int] = []
    /// Другие издания того же альбома: делюкс, ремастер, версия без мата.
    var versions: [Card] = []
}

struct ArtistPage: Codable {
    var id: String
    var name: String
    var cover: String?
    var popular: [Track]
    var extraTracks: [Track]? = nil
    var albums: [Card]
    /// Сборники и альбомы с участием исполнителя.
    var also: [Card] = []
    var similar: [Card] = []
    var singles: [Card] = []
    var playlists: [Playlist] = []
    /// Слушателей за месяц.
    var listeners: Int?
    var about = ""
    var latestRelease: Card?
    var clips: [ArtistClip]? = nil
    var concerts: [ArtistConcert]? = nil
}

struct ArtistClip: Codable, Identifiable {
    let id: String
    let title: String
    let cover: String?
    let url: URL
    var playerID: String? = nil
}

struct ConcertCity: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ArtistConcert: Codable, Identifiable {
    let id: String
    let title: String
    let city: String
    let venue: String
    let date: String
    let cover: String?
    let tickets: URL?
}

/// «1,2 млн», «34 тыс.»: число слушателей коротко.
func shortCount(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1f млн", Double(value) / 1_000_000).replacingOccurrences(of: ".0", with: "").replacingOccurrences(of: ".", with: ",")
    }
    if value >= 1_000 { return "\(value / 1_000) тыс." }
    return "\(value)"
}

/// Первое, что нашёл Яндекс: показывается крупной карточкой.
enum SearchBest: Codable {
    case track(Track)
    case artist(Card)
    case album(Card)
    case playlist(Playlist)
    case podcast(Card)
}

struct SearchResult: Codable {
    var best: SearchBest?
    var tracks: [Track] = []
    var albums: [Card] = []
    var artists: [Card] = []
    var playlists: [Playlist] = []
    var podcasts: [Card] = []
    var episodes: [Track] = []
    var hasMore = false

    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty && podcasts.isEmpty && episodes.isEmpty
    }

    mutating func append(_ page: SearchResult) {
        tracks = Self.merging(tracks, page.tracks)
        albums = Self.merging(albums, page.albums)
        artists = Self.merging(artists, page.artists)
        playlists = Self.merging(playlists, page.playlists)
        podcasts = Self.merging(podcasts, page.podcasts)
        episodes = Self.merging(episodes, page.episodes)
        hasMore = page.hasMore
    }

    private static func merging<Item: Identifiable>(_ previous: [Item], _ next: [Item]) -> [Item] {
        var ids = Set<Item.ID>()
        return (previous + next).filter { ids.insert($0.id).inserted }
    }
}

struct Wave {
    var session: String
    var tracks: [Track]
}

struct TrackFilter: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let trackIds: Set<String>

    static func select(_ raw: [TrackFilter], catalogIds: Set<String>) -> [TrackFilter] {
        guard catalogIds.count >= 4 else { return [] }
        let minTracks: Int
        if catalogIds.count >= 40 {
            minTracks = 8
        } else if catalogIds.count >= 16 {
            minTracks = 3
        } else {
            minTracks = 2
        }
        let selected: [TrackFilter] = raw.compactMap { filter in
            let id = filter.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id != "all", !id.isEmpty, !name.isEmpty else { return nil }
            let matched = filter.trackIds.intersection(catalogIds)
            guard matched.count >= minTracks, matched.count < catalogIds.count else { return nil }
            return TrackFilter(id: id, name: name, trackIds: matched)
        }
        let capped = Array(selected.prefix(7))
        return capped.count >= 2 ? capped : []
    }
}

struct FileInfo {
    var url: String
    var key: String?
    var codec: String
}

struct LyricLine: Identifiable, Codable {
    let id: Int
    let time: Double?
    let text: String
}

/// Откуда играет очередь: для отчётов о прослушивании.
struct PlayContext {
    var kind: String
    var item: String?
    var name: String

    static func various(_ name: String) -> PlayContext { PlayContext(kind: "various", item: nil, name: name) }
}

enum Cover {
    /// Адрес обложки нужного размера. У Яндекса в адресе стоит %% вместо размера.
    static func url(_ uri: String?, side: Int) -> URL? {
        guard var text = uri?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            if text.contains("%%") {
                text = text.replacingOccurrences(of: "%%", with: "\(side)x\(side)")
            }
            return URL(string: text)
        }
        text = text.replacingOccurrences(of: "%%", with: "\(side)x\(side)")
        if text.hasPrefix("//") {
            text = "https:" + text
        } else {
            text = "https://" + text
        }
        return URL(string: text)
    }
}

func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n = abs(count) % 100
    let last = n % 10
    if n > 10 && n < 20 { return "\(count) \(many)" }
    if last == 1 { return "\(count) \(one)" }
    if last >= 2 && last <= 4 { return "\(count) \(few)" }
    return "\(count) \(many)"
}

func timeText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
