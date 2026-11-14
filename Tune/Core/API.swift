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
        // Без этого названия волн и подборок приходят на языке телефона.
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        // «Слишком много запросов» бывает на запуске, когда всё грузится разом: ждём и повторяем.
        var waits: [UInt64] = [1, 3]
        while true {
            let answer: (Data, URLResponse)
            do {
                answer = try await http.data(for: request)
            } catch {
                if (error as? URLError)?.code != .cancelled {
                    Log.shared.add("сеть: \(parts.path): \(error.localizedDescription)")
                }
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
                Log.shared.add("api: \(parts.path): \(status) \(name)")
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
            batch: nil,
            loudness: value["r128"]["i"].double,
            peak: value["r128"]["tp"].double,
            // Точки перехода есть только у музыки: у подкастов и книг их нет.
            fade: value["type"].string == "music" ? FadePoints.parse(value["fade"]) : nil,
            mixFade: value["type"].string == "music" ? FadePoints.parse(value["mixFade"]) : nil)
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
        return Card(id: id, title: title, subtitle: subtitle, cover: value["coverUri"].string ?? value["cover"]["uri"].string)
    }

    /// Новинка с главной: альбом и исполнители лежат рядом.
    private static func releaseCard(_ value: JSON) -> Card? {
        let album = value["album"]
        guard let id = album["id"].idText, let title = album["title"].string else { return nil }
        let names = value["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        return Card(id: id, title: title, subtitle: names, cover: album["coverUri"].string ?? album["cover"]["uri"].string ?? value["cover"]["uri"].string)
    }

    /// Карточка полки главной: плейлист, исполнитель, альбом или волна.
    private static func homeItem(_ value: JSON) -> HomeItem? {
        // В блоках волн карточка лежит сразу, без обёртки data.
        let data = value["data"].isObject ? value["data"] : value
        if data["playlist"].isObject {
            let playlist = data["playlist"]
            guard let owner = playlist["uid"].idText ?? playlist["owner"]["uid"].idText else { return nil }
            guard var parsed = parsePlaylist(playlist, owner: owner) else { return nil }
            if parsed.count == 0, let count = data["trackCount"].int { parsed.count = count }
            return .playlist(parsed)
        }
        if data["artist"].isObject {
            guard let card = artistCard(data["artist"]) else { return nil }
            return .artist(card)
        }
        if data["album"].isObject {
            guard let card = albumCard(data["album"]) else { return nil }
            return .album(card)
        }
        let wave = data["wave"]
        let seeds = (data["seeds"].isArray ? data["seeds"] : wave["seeds"]).array.compactMap { $0.string }
        guard !seeds.isEmpty, let title = data["title"].string ?? wave["name"].string else { return nil }
        let cover = data["compactImageUrl"].string ?? data["agent"]["cover"]["uri"].string ?? data["imageUrl"].string ?? data["backgroundImageUrl"].string
        return .wave(WaveCard(title: title, seeds: seeds, cover: cover, color: data["colors"]["average"].string))
    }

    /// У блоков главной разные ответы, но элементы в них одни и те же.
    private static func homeItems(_ value: JSON) -> [HomeItem] {
        var items: [HomeItem] = []
        // Чарт приходит плейлистом внутри chart.
        let chart = value["chart"]
        if chart.isObject, let owner = chart["uid"].idText, let playlist = parsePlaylist(chart, owner: owner) {
            items.append(.playlist(playlist))
        }
        for release in value["newReleases"].array {
            if let card = releaseCard(release) { items.append(.album(card)) }
        }
        for item in value["items"].array {
            if let parsed = homeItem(item) { items.append(parsed) }
        }
        for group in ["waves", "inStyleTabs"] {
            for item in value[group][0]["items"].array {
                if let parsed = homeItem(item) { items.append(parsed) }
            }
        }
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
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
        if Demo.on { return Profile(uid: "demo", name: "Демо", login: "demo", plus: true) }
        let value = result(try await get("account/status"))
        let account = value["account"]
        guard let uid = account["uid"].idText else { throw APIError.server("Яндекс не сообщил номер аккаунта") }
        let name = account["displayName"].string ?? account["firstName"].string ?? account["login"].string ?? ""
        return Profile(uid: uid, name: name, login: account["login"].string ?? "", plus: value["plus"]["hasPlus"].bool ?? false)
    }

    /// Номера треков из «Мне нравится», сначала новые.
    func likedIds(uid: String) async throws -> [String] {
        if Demo.on { return Demo.data.tracks.map(\.id) }
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
        if Demo.on { return Demo.data.tracks.filter { ids.contains($0.id) } }
        let value = try await post("tracks", form: "track-ids=" + ids.joined(separator: "%2C"))
        var found: [String: Track] = [:]
        for track in value["result"].array.compactMap(Self.parseTrack) where found[track.id] == nil {
            found[track.id] = track
        }
        return ids.compactMap { found[$0] }
    }

    func playlists(uid: String) async throws -> [Playlist] {
        if Demo.on { return Demo.data.playlists }
        let value = try await get("users/\(uid)/playlists/list")
        return value["result"].array.compactMap { Self.parsePlaylist($0, owner: uid) }
    }

    func playlistTracks(_ playlist: Playlist) async throws -> [Track] {
        try await self.playlist(playlist).tracks
    }

    func playlist(_ playlist: Playlist) async throws -> PlaylistPage {
        if Demo.on {
            return PlaylistPage(tracks: Demo.data.tracks, author: "Демо", about: "Музыка в дорогу: от спокойного к бодрому, чтобы не уснуть за рулём.")
        }
        let value = result(try await get("users/\(playlist.owner)/playlists/\(playlist.kind)", [("rich-tracks", "true")]))
        return PlaylistPage(
            tracks: value["tracks"].array.compactMap { Self.parseTrack($0["track"]) },
            author: value["owner"]["name"].string ?? "",
            about: value["description"].string ?? "",
            title: value["title"].string ?? "",
            cover: Self.parsePlaylist(value, owner: playlist.owner)?.cover,
            open: value["visibility"].string.map { $0 == "public" })
    }

    // MARK: - Альбомы, исполнители, поиск

    func album(id: String) async throws -> AlbumPage {
        if Demo.on {
            let all = Demo.data.albums + Demo.data.releases
            guard let card = all.first(where: { $0.id == id }) ?? all.first else { throw APIError.server("Нет демо-данных") }
            var page = AlbumPage(card: card, year: 2024, tracks: Demo.data.tracks)
            page.artist = Demo.data.artists.first.map { ArtistRef(id: $0.id, name: $0.title) }
            page.label = "Warner Records"
            page.genre = "rock"
            page.disks = [8, max(1, Demo.data.tracks.count - 8)]
            page.versions = Array(all.filter { $0.id != card.id }.prefix(2))
            return page
        }
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
        var page = AlbumPage(card: card, year: value["year"].int, tracks: disks.flatMap { $0 })
        let artist = value["artists"][0]
        if let artistId = artist["id"].idText, let name = artist["name"].string {
            page.artist = ArtistRef(id: artistId, name: name)
        }
        page.label = value["labels"][0]["name"].string ?? value["labels"][0].string ?? ""
        page.genre = value["genre"].string ?? ""
        page.kind = value["type"].string ?? ""
        page.disks = disks.map(\.count).filter { $0 > 0 }
        page.versions = value["duplicates"].array.compactMap(Self.albumCard).filter { $0.id != id }
        return page
    }

    func albums(ids: [String]) async throws -> [Card] {
        guard !ids.isEmpty else { return [] }
        let value = try await post("albums", form: "album-ids=" + ids.joined(separator: "%2C"))
        return value["result"].array.compactMap(Self.albumCard)
    }

    func artist(id: String) async throws -> ArtistPage {
        if Demo.on {
            guard let card = Demo.data.artists.first(where: { $0.id == id }) ?? Demo.data.artists.first else { throw APIError.server("Нет демо-данных") }
            var page = ArtistPage(id: card.id, name: card.title, cover: card.cover, popular: Demo.data.tracks, albums: Demo.data.albums, similar: Demo.data.artists)
            page.singles = Demo.data.releases
            page.playlists = Demo.data.playlists
            page.listeners = 12_400_000
            page.about = "Британская рок-группа, добившаяся широчайшей известности в середине 1970-х годов, и одна из наиболее успешных групп в истории рок-музыки."
            return page
        }
        let value = result(try await get("artists/\(id)/brief-info"))
        let artist = value["artist"]
        guard let name = artist["name"].string, artist["error"].string != "not-found" else { throw APIError.server("Исполнитель не найден") }
        var popular = value["popularTracks"].array.compactMap(Self.parseTrack)
        let releases = value["albums"].array
        var albums = releases.filter { $0["type"].string != "single" }.compactMap(Self.albumCard)
        let singles = releases.filter { $0["type"].string == "single" }.compactMap(Self.albumCard)
        let playlists = value["playlists"].array.compactMap { item -> Playlist? in
            guard let owner = item["uid"].idText ?? item["owner"]["uid"].idText else { return nil }
            return Self.parsePlaylist(item, owner: owner)
        }
        // Добавленные в профиль треки — в начало популярных, альбомы — в начало альбомов.
        let inserts = Uncensor.shared.inserts(artist: id)
        if let extra = try? await tracks(ids: inserts.tracks) {
            popular.insert(contentsOf: extra.filter { track in !popular.contains { $0.id == track.id } }, at: 0)
        }
        if let extra = try? await self.albums(ids: inserts.albums) {
            albums.insert(contentsOf: extra.filter { card in !albums.contains { $0.id == card.id } }, at: 0)
        }
        var page = ArtistPage(
            id: id, name: name, cover: artist["cover"]["uri"].string ?? artist["ogImage"].string, popular: popular, albums: albums,
            also: value["alsoAlbums"].array.compactMap(Self.albumCard), similar: value["similarArtists"].array.compactMap(Self.artistCard))
        page.singles = singles
        page.playlists = playlists
        page.listeners = value["stats"]["lastMonthListeners"].int
        page.about = artist["description"]["text"].string ?? ""
        return page
    }

    func artistTracks(id: String) async throws -> [Track] {
        if Demo.on { return Demo.data.tracks }
        let value = result(try await get("artists/\(id)/tracks", [("page-size", "200")]))
        return value["tracks"].array.compactMap(Self.parseTrack)
    }

    /// `types` — что искать через запятую: track, album, artist, playlist.
    /// Подсказки: как Яндекс предлагает закончить запрос.
    func suggest(_ text: String) async throws -> [String] {
        if Demo.on { return ["queen bohemian rhapsody", "queen of the damned", "queens of the stone age", "queencard"] }
        let value = result(try await get("search/suggest", [("part", text)]))
        return value["suggestions"].array.compactMap { $0.string }
    }

    func search(_ text: String, types: String = "track,album,artist,playlist", size: Int = 36) async throws -> SearchResult {
        if Demo.on {
            var demo = SearchResult(tracks: Demo.data.tracks, albums: Demo.data.albums, artists: Demo.data.artists, playlists: Demo.data.playlists)
            demo.best = Demo.data.artists.first.map { .artist($0) }
            return demo
        }
        let value = result(try await get("search/instant/mixed", [("text", text), ("type", types), ("page", "0"), ("pageSize", "\(size)")]))
        var found = SearchResult()
        // Результаты идут по убыванию точности: первый из них и есть лучший.
        for item in value["results"].array {
            switch item["type"].string {
            case "track":
                if let track = Self.parseTrack(item["track"]) {
                    if found.best == nil { found.best = .track(track) }
                    found.tracks.append(track)
                }
            case "album":
                if let card = Self.albumCard(item["album"]) {
                    if found.best == nil { found.best = .album(card) }
                    found.albums.append(card)
                }
            case "artist":
                if let card = Self.artistCard(item["artist"]) {
                    if found.best == nil { found.best = .artist(card) }
                    found.artists.append(card)
                }
            case "playlist":
                let owner = item["playlist"]["uid"].idText ?? ""
                if let playlist = Self.parsePlaylist(item["playlist"], owner: owner) {
                    if found.best == nil { found.best = .playlist(playlist) }
                    found.playlists.append(playlist)
                }
            default:
                break
            }
        }
        return found
    }

    /// Альбомы и исполнители, которые нравятся пользователю.
    func likedAlbums(uid: String) async throws -> [Card] {
        if Demo.on { return Demo.data.albums }
        let value = result(try await get("users/\(uid)/likes/albums", [("rich", "true")]))
        return value.array.compactMap { Self.albumCard($0["album"]) }
    }

    func likedArtists(uid: String) async throws -> [Card] {
        if Demo.on { return Demo.data.artists }
        let value = result(try await get("users/\(uid)/likes/artists", [("with-timestamps", "false")]))
        // Исполнитель приходит то сам по себе, то внутри artist.
        return value.array.compactMap { Self.artistCard($0) ?? Self.artistCard($0["artist"]) }
    }

    func likedPlaylists(uid: String) async throws -> [Playlist] {
        if Demo.on { return Demo.data.personal }
        let value = result(try await get("users/\(uid)/likes/playlists"))
        return value.array.compactMap { item -> Playlist? in
            let playlist = item["playlist"].isObject ? item["playlist"] : item
            guard let owner = playlist["uid"].idText ?? playlist["owner"]["uid"].idText else { return nil }
            return Self.parsePlaylist(playlist, owner: owner)
        }
    }

    /// Номера альбомов и исполнителей из коллекции и треков с дизлайком: по ним рисуются сердечки.
    func likedAlbumIds(uid: String) async throws -> [String] {
        if Demo.on { return [] }
        let value = result(try await get("users/\(uid)/likes/albums"))
        return value.array.compactMap { $0["id"].idText ?? $0["album"]["id"].idText }
    }

    func likedArtistIds(uid: String) async throws -> [String] {
        if Demo.on { return [] }
        let value = result(try await get("users/\(uid)/likes/artists", [("with-timestamps", "false")]))
        return value.array.compactMap { $0["id"].idText ?? $0["artist"]["id"].idText }
    }

    func dislikedIds(uid: String) async throws -> [String] {
        if Demo.on { return [] }
        let value = result(try await get("users/\(uid)/dislikes/tracks"))
        return value["library"]["tracks"].array.compactMap { $0["id"].idText }
    }

    /// Дизлайк: Яндекс больше не предложит этот трек.
    func setDisliked(uid: String, track: String, disliked: Bool) async throws {
        _ = try await post(disliked ? "users/\(uid)/dislikes/tracks/add?track-id=\(track)" : "users/\(uid)/dislikes/tracks/\(track)/remove")
    }

    /// kind — albums или artists, param — album-id или artist-id.
    func setLiked(uid: String, kind: String, param: String, id: String, liked: Bool) async throws {
        _ = try await post(liked ? "users/\(uid)/likes/\(kind)/add?\(param)=\(id)" : "users/\(uid)/likes/\(kind)/\(id)/remove")
    }

    func setLiked(uid: String, playlist: Playlist, liked: Bool) async throws {
        _ = try await post(liked ? "users/\(uid)/likes/playlists/add?owner-uid=\(playlist.owner)&kind=\(playlist.kind)" : "users/\(uid)/likes/playlists/\(playlist.owner)-\(playlist.kind)/remove")
    }

    // MARK: - Свои плейлисты

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    func createPlaylist(uid: String, title: String) async throws -> Playlist {
        let value = result(try await post("users/\(uid)/playlists/create?visibility=private&title=\(Self.encode(title))"))
        guard let playlist = Self.parsePlaylist(value, owner: uid) else { throw APIError.server("Яндекс не создал плейлист") }
        return playlist
    }

    func renamePlaylist(uid: String, kind: String, title: String) async throws {
        _ = try await post("users/\(uid)/playlists/\(kind)/name?value=\(Self.encode(title))")
    }

    func setPlaylistOpen(uid: String, kind: String, _ open: Bool) async throws {
        _ = try await post("users/\(uid)/playlists/\(kind)/visibility?value=\(open ? "public" : "private")")
    }

    func deletePlaylist(uid: String, kind: String) async throws {
        _ = try await post("users/\(uid)/playlists/\(kind)/delete")
    }

    /// Плейлист меняют от его последней версии, поэтому она читается перед каждым изменением.
    /// Правка плейлиста: Яндекс принимает список операций и номер версии, с которой они сняты.
    private func change(uid: String, kind: String, _ diff: (JSON) throws -> [[String: Any]]) async throws {
        let state = result(try await get("users/\(uid)/playlists/\(kind)", [("rich-tracks", "true")]))
        let operations = try diff(state)
        let body = try JSONSerialization.data(withJSONObject: operations)
        let text = String(data: body, encoding: .utf8) ?? "[]"
        _ = try await post("users/\(uid)/playlists/\(kind)/change-relative", form: "diff=\(Self.encode(text))&revision=\(state["revision"].int ?? 0)")
    }

    private static func reference(_ track: Track) -> [String: Any] {
        var out: [String: Any] = ["id": track.id]
        if let album = track.albumId { out["albumId"] = album }
        return out
    }

    /// Положение трека в плейлисте, как его хранит Яндекс.
    private static func position(of id: String, in state: JSON) -> Int? {
        state["tracks"].array.firstIndex { ($0["track"]["id"].idText ?? $0["id"].idText) == id }
    }

    func addToPlaylist(uid: String, kind: String, tracks: [Track]) async throws {
        try await change(uid: uid, kind: kind) { _ in
            [["op": "insert", "at": 0, "tracks": tracks.map(Self.reference)]]
        }
    }

    func removeFromPlaylist(uid: String, kind: String, track: Track) async throws {
        try await change(uid: uid, kind: kind) { state in
            guard let position = Self.position(of: track.id, in: state) else {
                throw APIError.server("Трека уже нет в плейлисте")
            }
            return [["op": "delete", "from": position, "to": position + 1, "tracks": [Self.reference(track)]]]
        }
    }

    /// Переставляет трек: он встаёт перед треком `before`, а без него — в конец.
    func moveInPlaylist(uid: String, kind: String, track: Track, before: String?) async throws {
        try await change(uid: uid, kind: kind) { state in
            guard let from = Self.position(of: track.id, in: state) else {
                throw APIError.server("Трека уже нет в плейлисте")
            }
            var target = state["tracks"].array.count - 1
            if let before, let next = Self.position(of: before, in: state) {
                // После удаления трека всё, что стояло за ним, сдвигается на одну позицию.
                target = next > from ? next - 1 : next
            }
            let reference = Self.reference(track)
            return [
                ["op": "delete", "from": from, "to": from + 1, "tracks": [reference]],
                ["op": "insert", "at": target, "tracks": [reference]],
            ]
        }
    }

    /// Последние прослушанные треки, новые сначала и без повторов.
    /// История и дни: у первого трека каждого дня — подпись «Сегодня», «Вчера» или дата.
    func history(limit: Int = 200) async throws -> (tracks: [Track], days: [String: String]) {
        if Demo.on {
            let list = Array(Demo.data.tracks.reversed())
            var days: [String: String] = [:]
            if let first = list.first { days[first.id] = "Сегодня" }
            if list.count > 4 { days[list[4].id] = "Вчера" }
            return (list, days)
        }
        let value = result(try await get("music-history", [("fullModelsCount", "0")]))
        var ids: [String] = []
        var dayOf: [String: String] = [:]
        var seen = Set<String>()
        for tab in value["historyTabs"].array {
            let day = Self.dayName(tab["date"].string ?? "")
            for item in tab["items"].array {
                for track in item["tracks"].array {
                    if let id = track["data"]["itemId"]["trackId"].idText, seen.insert(id).inserted {
                        ids.append(id)
                        dayOf[id] = day
                    }
                }
            }
        }
        var out: [Track] = []
        for chunk in Array(ids.prefix(limit)).chunked(150) {
            out += try await tracks(ids: chunk)
        }
        var days: [String: String] = [:]
        var last = ""
        for track in out {
            let day = dayOf[track.id] ?? ""
            if !day.isEmpty, day != last { days[track.id] = day }
            if !day.isEmpty { last = day }
        }
        return (out, days)
    }

    /// «2026-11-12» → «Сегодня», «Вчера» или «12 ноября».
    private static func dayName(_ text: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(text.prefix(10))) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Сегодня" }
        if calendar.isDateInYesterday(date) { return "Вчера" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        out.dateFormat = sameYear ? "d MMMM" : "d MMMM yyyy"
        return out.string(from: date)
    }

    // MARK: - Главная

    /// Полки главной, как у официального клиента: скелет страницы и блоки первой вкладки.
    /// Блоки грузятся одновременно, порядок сохраняется.
    func home() async throws -> HomePage {
        if Demo.on { return HomePage(waves: Demo.data.waves, blocks: Demo.home) }
        let skeleton = result(try await get("landing/skeleton/main"))
        let tabs = skeleton["blocks"].array.map { $0["data"]["tabs"] }.first { $0.isArray } ?? JSON(nil)
        // Эти блоки ведут в разделы, которых в приложении нет.
        let skipped: Set<String> = ["LIKES_AND_HISTORY", "SPECIAL", "CONCERTS_PERSONAL", "DONATIONS", "ALBUM_PROMO"]
        var kinds: [String] = []
        var titles: [String] = []
        var paths: [String] = []
        for block in tabs[0]["blocks"].array {
            let kind = block["type"].string ?? ""
            guard !skipped.contains(kind), let uri = block["data"]["source"]["uri"].string else { continue }
            kinds.append(kind)
            titles.append(block["data"]["title"].string ?? "")
            paths.append(uri.hasPrefix("/") ? String(uri.dropFirst()) : uri)
        }
        let loaded = await withTaskGroup(of: (Int, [HomeItem]).self) { group -> [Int: [HomeItem]] in
            for (index, path) in paths.enumerated() {
                group.addTask {
                    guard let value = try? await self.get(path) else { return (index, []) }
                    return (index, Self.homeItems(self.result(value)))
                }
            }
            var out: [Int: [HomeItem]] = [:]
            for await (index, items) in group { out[index] = items }
            return out
        }
        var page = HomePage()
        for index in paths.indices {
            let items = loaded[index] ?? []
            guard !items.isEmpty else { continue }
            if kinds[index] == "WAVES" {
                for item in items {
                    if case .wave(let wave) = item { page.waves.append(wave) }
                }
            } else if !titles[index].isEmpty {
                page.blocks.append(HomeBlock(id: "\(index):\(paths[index])", title: titles[index], items: items))
            }
        }
        return page
    }

    // MARK: - Волна

    /// Полный список волн Яндекса по группам: жанры, настроение, занятие, эпоха.
    func stations() async throws -> [StationGroup] {
        if Demo.on {
            let genres = [("pop", "Поп"), ("rock", "Рок"), ("rap", "Рэп и хип-хоп"), ("electronics", "Электроника"), ("indie", "Инди"), ("metal", "Метал"), ("jazz", "Джаз"), ("classical", "Классика")]
            return [
                StationGroup(id: "genre", title: "Жанры", waves: genres.map { WaveCard(title: $0.1, seeds: ["genre:" + $0.0], cover: nil, color: nil) }),
                StationGroup(id: "mood", title: "Настроение", waves: Demo.data.waves),
            ]
        }
        let value = result(try await get("rotor/stations/list", [("language", "ru")]))
        var found: [String: [WaveCard]] = [:]
        for item in value.array {
            let station = item["station"]
            guard let type = station["id"]["type"].string, let tag = station["id"]["tag"].string, let name = station["name"].string else { continue }
            found[type, default: []].append(WaveCard(title: name, seeds: ["\(type):\(tag)"], cover: nil, color: station["icon"]["backgroundColor"].string))
        }
        return StationGroup.known.compactMap { group in
            guard let waves = found[group.id], !waves.isEmpty else { return nil }
            return StationGroup(id: group.id, title: group.title, waves: waves)
        }
    }

    /// «Не рекомендовать исполнителя»: его треки перестают попадаться в волнах.
    func setBlocked(uid: String, artist: String, blocked: Bool) async throws {
        _ = try await post("users/\(uid)/dislikes/artists/" + (blocked ? "add-multiple" : "remove"), form: "artist-ids=" + artist)
    }

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
        if Demo.on { return Demo.lyrics }
        // Однажды полученный текст лежит на устройстве: он есть и без сети.
        _ = Storage.lyrics
        let name = "Lyrics/\(Storage.hash(id)).json"
        if let saved = Storage.load(name, as: [LyricLine].self), !Self.isStub(saved) { return saved }
        let lines = try await fetchLyrics(track: id)
        // Аккаунту без Плюса Яндекс вместо текста отдаёт просьбу подключить подписку.
        // Её нельзя сохранять: иначе она останется и после входа в аккаунт с Плюсом.
        if Self.isStub(lines) {
            Storage.remove(name)
            return []
        }
        if !lines.isEmpty { Storage.save(lines, name) }
        return lines
    }

    /// Вместо текста пришла заглушка про подписку: пара строк со словом «подписка».
    private static func isStub(_ lines: [LyricLine]) -> Bool {
        let words = lines.map(\.text).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 4 else { return false }
        return words.joined(separator: " ").lowercased().contains("подписк")
    }

    private func fetchLyrics(track id: String) async throws -> [LyricLine] {
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
