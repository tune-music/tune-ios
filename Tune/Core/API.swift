import CryptoKit
import Foundation

enum APIError: LocalizedError {
    case needLogin
    case busy
    case server(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .needLogin: return "Нужно войти в аккаунт заново"
        case .busy: return "Яндекс просит подождать: слишком много запросов"
        case .server(let text): return text
        case .network: return "Нет связи с Яндексом"
        }
    }

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }
}

/// Запросы к API Яндекс Музыки — те же, что шлёт официальный клиент.
final class API {
    static let shared = API()

    private let base = "https://api.music.yandex.net"
    private let client = "YandexMusicDesktopAppWindows/5.120.0"
    private let signKey = SymmetricKey(data: Data("kzqU4XhfCaY6B6JTHODeq5".utf8))
    private let from = "tune-ios"
    private let http: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: - Транспорт

    private func send(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, type: String? = nil) async throws -> JSON {
        guard let token = TokenStore.token else { throw APIError.needLogin }
        guard var parts = URLComponents(string: "\(base)/\(path)") else { throw APIError.server("Неверный адрес запроса") }
        if !query.isEmpty {
            parts.queryItems = (parts.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // В подписи бывает «+», а URLComponents его не кодирует.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw APIError.server("Неверный адрес запроса") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(client, forHTTPHeaderField: "X-Yandex-Music-Client")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        // «Слишком много запросов» бывает на запуске, когда всё грузится разом: ждём и повторяем.
        var waits: [UInt64] = [1, 3]
        while true {
            let answer: (Data, URLResponse)
            do {
                answer = try await http.data(for: request)
            } catch {
                throw APIError.network(error.localizedDescription)
            }
            let status = (answer.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw APIError.needLogin }
            if status == 429 {
                guard !waits.isEmpty else { throw APIError.busy }
                try await Task.sleep(nanoseconds: waits.removeFirst() * 1_000_000_000)
                continue
            }
            let value = JSON.parse(answer.0)
            if status != 200 {
                let name = value["error"]["name"].string ?? value["result"]["message"].string ?? "ошибка"
                throw APIError.server("Яндекс ответил \(status): \(name)")
            }
            guard value.exists else { throw APIError.server("Яндекс ответил \(status)") }
            return value
        }
    }

    private func get(_ path: String, _ query: [(String, String)] = []) async throws -> JSON {
        try await send("GET", path, query: query)
    }

    private func post(_ path: String, form: String = "") async throws -> JSON {
        try await send("POST", path, body: Data(form.utf8), type: "application/x-www-form-urlencoded")
    }

    private func post(_ path: String, json: [String: Any], query: [(String, String)] = []) async throws -> JSON {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send("POST", path, query: query, body: body, type: "application/json")
    }

    /// Часть ответов лежит в result, часть — сразу в корне.
    private func result(_ value: JSON) -> JSON {
        let inner = value["result"]
        return inner.isObject || inner.isArray ? inner : value
    }

    // MARK: - Разбор

    static func parseTrack(_ source: JSON) -> Track? {
        var value = source
        var uncensored = false
        if let fields = source.dict, let id = source["id"].idText, let patched = Uncensor.shared.patch(track: fields, id: id) {
            value = JSON(patched.fields)
            uncensored = patched.file
        }
        guard let id = value["id"].idText, let title = value["title"].string else { return nil }
        let artists = value["artists"].array.compactMap { artist -> ArtistRef? in
            guard let name = artist["name"].string else { return nil }
            return ArtistRef(id: artist["id"].idText ?? "", name: name)
        }
        let album = value["albums"][0]
        let cover = value["coverUri"].string ?? album["coverUri"].string
        let lyrics = value["lyricsInfo"]
        return Track(
            id: id,
            title: title,
            version: value["version"].string,
            artists: artists.map(\.name).joined(separator: ", "),
            artistList: artists,
            durationMs: value["durationMs"].int ?? 0,
            cover: (cover?.isEmpty ?? true) ? nil : cover,
            albumId: album["id"].idText,
            albumTitle: album["title"].string ?? "",
            explicit: value["contentWarning"].string == "explicit",
            hasLyrics: lyrics["hasAvailableSyncLyrics"].bool == true || lyrics["hasAvailableTextLyrics"].bool == true,
            unavailable: value["available"].bool == false,
            uncensored: uncensored,
            batch: nil)
    }

    private static func parsePlaylist(_ value: JSON, owner: String) -> Playlist? {
        guard let kind = value["kind"].idText, let title = value["title"].string else { return nil }
        let cover = value["cover"]["uri"].string ?? value["cover"]["itemsUri"][0].string ?? value["ogImage"].string
        return Playlist(
            owner: value["owner"]["uid"].idText ?? value["uid"].idText ?? owner,
            kind: kind,
            title: title,
            count: value["trackCount"].int ?? 0,
            cover: (cover?.isEmpty ?? true) ? nil : cover)
    }

    private static func albumCard(_ source: JSON) -> Card? {
        var value = source
        if let fields = source.dict, let id = source["id"].idText, let patched = Uncensor.shared.patch(album: fields, id: id) {
            value = JSON(patched)
        }
        guard let id = value["id"].idText, let title = value["title"].string else { return nil }
        var subtitle = value["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        if let year = value["year"].int {
            subtitle = subtitle.isEmpty ? "\(year)" : "\(subtitle) · \(year)"
        }
        return Card(id: id, title: title, subtitle: subtitle, cover: value["coverUri"].string)
    }

    private static func artistCard(_ value: JSON) -> Card? {
        guard let id = value["id"].idText, let name = value["name"].string else { return nil }
        let cover = value["cover"]["uri"].string ?? value["ogImage"].string
        return Card(id: id, title: name, subtitle: "Исполнитель", cover: cover)
    }

    private static func parseSequence(_ value: JSON) -> [Track] {
        let batch = value["batchId"].string
        return value["sequence"].array.compactMap { item in
            guard var track = parseTrack(item["track"]) else { return nil }
            track.batch = batch
            return track
        }
    }

    // MARK: - Аккаунт и коллекция

    func profile() async throws -> Profile {
        let value = result(try await get("account/status"))
        let account = value["account"]
        guard let uid = account["uid"].idText else { throw APIError.server("Яндекс не сообщил номер аккаунта") }
        let name = account["displayName"].string ?? account["firstName"].string ?? account["login"].string ?? ""
        return Profile(uid: uid, name: name, login: account["login"].string ?? "", plus: value["plus"]["hasPlus"].bool ?? false)
    }

    /// Номера треков из «Мне нравится», сначала новые.
    func likedIds(uid: String) async throws -> [String] {
        let value = result(try await get("users/\(uid)/likes/tracks"))
        return value["library"]["tracks"].array.compactMap { $0["id"].idText }
    }

    func setLiked(uid: String, track: String, liked: Bool) async throws {
        let path = liked ? "users/\(uid)/likes/tracks/add?track-id=\(track)" : "users/\(uid)/likes/tracks/\(track)/remove"
        let value = result(try await post(path))
        if !value["revision"].exists { throw APIError.server("Яндекс не сохранил лайк") }
    }

    /// Сведения о треках в том же порядке, что и номера.
    func tracks(ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let value = try await post("tracks", form: "track-ids=" + ids.joined(separator: "%2C"))
        var found: [String: Track] = [:]
        for track in value["result"].array.compactMap(Self.parseTrack) where found[track.id] == nil {
            found[track.id] = track
        }
        return ids.compactMap { found[$0] }
    }

    func playlists(uid: String) async throws -> [Playlist] {
        let value = try await get("users/\(uid)/playlists/list")
        return value["result"].array.compactMap { Self.parsePlaylist($0, owner: uid) }
    }

    func playlistTracks(_ playlist: Playlist) async throws -> [Track] {
        let value = result(try await get("users/\(playlist.owner)/playlists/\(playlist.kind)", [("rich-tracks", "true")]))
        return value["tracks"].array.compactMap { Self.parseTrack($0["track"]) }
    }

    // MARK: - Альбомы, исполнители, поиск

    func album(id: String) async throws -> AlbumPage {
        let value = result(try await get("albums/\(id)/with-tracks"))
        if value["error"].string == "not-found" { throw APIError.server("Альбом не найден") }
        var disks: [[Track]] = value["volumes"].array.map { $0.array.compactMap(Self.parseTrack) }
        // Без цензуры: треки по дискам, как в списке FckCensor, с удалёнными Яндексом.
        if let want = Uncensor.shared.volumes(album: id) {
            var have: [String: Track] = [:]
            for track in disks.flatMap({ $0 }) { have[track.id] = track }
            let missing = want.flatMap { $0 }.filter { have[$0] == nil }
            if !missing.isEmpty, let extra = try? await tracks(ids: missing) {
                for track in extra { have[track.id] = track }
            }
            var listed = Set<String>()
            var rebuilt: [[Track]] = want.map { disk in
                disk.compactMap { id -> Track? in
                    listed.insert(id)
                    return have[id]
                }
            }
            let rest = disks.flatMap { $0 }.filter { !listed.contains($0.id) }
            if !rest.isEmpty { rebuilt.append(rest) }
            disks = rebuilt
        }
        guard let card = Self.albumCard(value) else { throw APIError.server("Яндекс не прислал альбом") }
        return AlbumPage(card: card, year: value["year"].int, tracks: disks.flatMap { $0 })
    }

    func albums(ids: [String]) async throws -> [Card] {
        guard !ids.isEmpty else { return [] }
        let value = try await post("albums", form: "album-ids=" + ids.joined(separator: "%2C"))
        return value["result"].array.compactMap(Self.albumCard)
    }

    func artist(id: String) async throws -> ArtistPage {
        let value = result(try await get("artists/\(id)/brief-info"))
        let artist = value["artist"]
        guard let name = artist["name"].string, artist["error"].string != "not-found" else { throw APIError.server("Исполнитель не найден") }
        var popular = value["popularTracks"].array.compactMap(Self.parseTrack)
        var albums = value["albums"].array.compactMap(Self.albumCard)
        // Добавленные в профиль треки — в начало популярных, альбомы — в начало альбомов.
        let inserts = Uncensor.shared.inserts(artist: id)
        if let extra = try? await tracks(ids: inserts.tracks) {
            popular.insert(contentsOf: extra.filter { track in !popular.contains { $0.id == track.id } }, at: 0)
        }
        if let extra = try? await self.albums(ids: inserts.albums) {
            albums.insert(contentsOf: extra.filter { card in !albums.contains { $0.id == card.id } }, at: 0)
        }
        return ArtistPage(id: id, name: name, cover: artist["cover"]["uri"].string ?? artist["ogImage"].string, popular: popular, albums: albums)
    }

    func artistTracks(id: String) async throws -> [Track] {
        let value = result(try await get("artists/\(id)/tracks", [("page-size", "200")]))
        return value["tracks"].array.compactMap(Self.parseTrack)
    }

    func search(_ text: String) async throws -> SearchResult {
        let value = result(try await get("search/instant/mixed", [("text", text), ("type", "track,album,artist,playlist"), ("page", "0"), ("pageSize", "36")]))
        var found = SearchResult()
        for item in value["results"].array {
            switch item["type"].string {
            case "track":
                if let track = Self.parseTrack(item["track"]) { found.tracks.append(track) }
            case "album":
                if let card = Self.albumCard(item["album"]) { found.albums.append(card) }
            case "artist":
                if let card = Self.artistCard(item["artist"]) { found.artists.append(card) }
            case "playlist":
                let owner = item["playlist"]["uid"].idText ?? ""
                if let playlist = Self.parsePlaylist(item["playlist"], owner: owner) { found.playlists.append(playlist) }
            default:
                break
            }
        }
        return found
    }

    // MARK: - Волна

    func waveNew(seeds: [String]) async throws -> Wave {
        let value = result(try await post("rotor/session/new", json: ["seeds": seeds, "includeTracksInResponse": true, "allowExplicit": true]))
        guard let session = value["radioSessionId"].string else { throw APIError.server("Яндекс не запустил волну") }
        return Wave(session: session, tracks: Self.parseSequence(value))
    }

    /// Следующая пачка волны; queue — уже показанные треки.
    func waveMore(session: String, queue: [String]) async throws -> [Track] {
        let value = result(try await post("rotor/session/\(session)/tracks", json: ["queue": queue, "allowExplicit": true]))
        return Self.parseSequence(value)
    }

    /// Что волна узнаёт о вкусе: запуск, начало, конец, пропуск.
    func waveFeedback(session: String, kind: String, track: Track?, played: Double?) async throws {
        var event: [String: Any] = ["type": kind, "timestamp": Self.now()]
        var body: [String: Any] = ["from": from]
        if let track {
            event["trackId"] = track.fullId
            if let batch = track.batch { body["batchId"] = batch }
            if let played { event["totalPlayedSeconds"] = played }
        } else {
            event["from"] = from
        }
        body["event"] = event
        _ = try await post("rotor/session/\(session)/feedback/", json: body)
    }

    /// Отчёты о прослушивании: по ним Яндекс ведёт историю и подбирает рекомендации.
    func plays(_ reports: [[String: Any]]) async throws {
        _ = try await post("plays", json: ["plays": reports], query: [("clientNow", Self.now())])
    }

    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - Файлы и тексты

    private func signFull(_ text: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: signKey)).base64EncodedString()
    }

    /// Как в оригинале: подпись без последнего символа.
    private func sign(_ text: String) -> String {
        String(signFull(text).dropLast())
    }

    /// Ссылка на файл трека. raw — обычный файл, который плеер играет потоком;
    /// encraw — зашифрованный, его надо скачать целиком.
    func fileInfo(track id: String, quality: String, transport: String) async throws -> FileInfo {
        let stamp = String(Int(Date().timeIntervalSince1970))
        // FLAC не просим: плеер iOS не играет его потоком из MP4.
        let codecs = ["aac-mp4", "he-aac-mp4", "mp3"]
        let signature = sign("\(stamp)\(id)\(quality)\(codecs.joined())\(transport)")
        let value = try await get("get-file-info", [
            ("ts", stamp), ("trackId", id), ("quality", quality), ("codecs", codecs.joined(separator: ",")),
            ("transports", transport), ("sign", signature),
        ])
        let info = result(value)["downloadInfo"]
        guard let url = info["url"].string ?? info["urls"][0].string else { throw APIError.server("Яндекс не дал файл трека") }
        let key = info["key"].string
        return FileInfo(url: url, key: (key?.isEmpty ?? true) ? nil : key, codec: info["codec"].string ?? "mp3")
    }

    /// Сначала синхронный текст, потом обычный.
    func lyrics(track id: String) async throws -> [LyricLine] {
        for format in ["LRC", "TEXT"] {
            let stamp = String(Int(Date().timeIntervalSince1970))
            let value: JSON
            do {
                value = result(try await get("tracks/\(id)/lyrics", [("format", format), ("timeStamp", stamp), ("sign", signFull("\(id)\(stamp)"))]))
            } catch APIError.server {
                continue
            }
            guard let link = value["downloadUrl"].string, let url = URL(string: link) else { continue }
            guard let (data, _) = try? await http.data(from: url), let text = String(data: data, encoding: .utf8) else { continue }
            let lines = Self.parseLRC(text)
            if lines.contains(where: { !$0.text.isEmpty }) { return lines }
        }
        return []
    }

    private static func parseLRC(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            var time: Double?
            var words = line
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let stamp = line[line.index(after: line.startIndex)..<close]
                let parts = stamp.split(separator: ":")
                if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
                    time = minutes * 60 + seconds
                    words = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    // Служебная строка вроде [ar:…] — не текст.
                    continue
                }
            }
            if time == nil && words.isEmpty { continue }
            out.append(LyricLine(id: out.count, time: time, text: words))
        }
        return out
    }
}
