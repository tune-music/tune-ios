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
    var double: Double? { (raw as? NSNumber)?.doubleValue }

    /// Номер трека, альбома или исполнителя: строкой или числом.
    var idText: String? {
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }
}

struct ArtistRef: Codable, Hashable {
    var id: String
    var name: String
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

    var duration: Double { Double(durationMs) / 1000 }

    /// Так трек называют волна и отчёты: id:альбом.
    var fullId: String {
        albumId.map { "\(id):\($0)" } ?? id
    }

    var shareURL: URL? {
        URL(string: albumId.map { "https://music.yandex.ru/album/\($0)/track/\(id)" } ?? "https://music.yandex.ru/track/\(id)")
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

    var id: String { "\(owner):\(kind)" }

    var shareURL: URL? {
        URL(string: "https://music.yandex.ru/users/\(owner)/playlists/\(kind)")
    }
}

/// Карточка альбома или исполнителя.
struct Card: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var cover: String?
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
}

struct Profile: Codable {
    var uid: String
    var name: String
    var login: String
    var plus: Bool
}

struct AlbumPage {
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
}

struct ArtistPage {
    var id: String
    var name: String
    var cover: String?
    var popular: [Track]
    var albums: [Card]
    /// Сборники и альбомы с участием исполнителя.
    var also: [Card] = []
    var similar: [Card] = []
    var singles: [Card] = []
    var playlists: [Playlist] = []
    /// Слушателей за месяц.
    var listeners: Int?
    var about = ""
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
enum SearchBest {
    case track(Track)
    case artist(Card)
    case album(Card)
    case playlist(Playlist)
}

struct SearchResult {
    var best: SearchBest?
    var tracks: [Track] = []
    var albums: [Card] = []
    var artists: [Card] = []
    var playlists: [Playlist] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

struct Wave {
    var session: String
    var tracks: [Track]
}

struct FileInfo {
    var url: String
    var key: String?
    var codec: String
}

struct LyricLine: Identifiable {
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
        guard var text = uri, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "%%", with: "\(side)x\(side)")
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
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
