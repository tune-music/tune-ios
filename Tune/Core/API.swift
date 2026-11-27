import AVFoundation
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
    private let lyricsInFlight = LyricsInFlight()
    private let http: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: - Транспорт

    private func send(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, type: String? = nil,
                      timeout: TimeInterval? = nil, missingStatuses: Set<Int> = []) async throws -> JSON {
        try Task.checkCancellation()
        guard await Connectivity.shared.online else { throw APIError.network("") }
        guard let token = TokenStore.token else { throw APIError.needLogin }
        guard var parts = URLComponents(string: "\(base)/\(path)") else { throw APIError.server("Неверный адрес запроса") }
        if !query.isEmpty {
            parts.queryItems = (parts.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // В подписи бывает «+», а URLComponents его не кодирует.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw APIError.server("Неверный адрес запроса") }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(client, forHTTPHeaderField: "X-Yandex-Music-Client")
        // Без этого названия волн и подборок приходят на языке телефона.
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        // «Слишком много запросов» бывает на запуске, когда всё грузится разом: ждём и повторяем.
        var waits: [UInt64] = timeout == nil ? [1, 3] : []
        while true {
            let answer: (Data, URLResponse)
            do {
                answer = try await http.data(for: request)
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code != .cancelled {
                    Log.shared.add("сеть: \(parts.path): \(error.localizedDescription)")
                }
                throw APIError.network(error.localizedDescription)
            }
            let status = (answer.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { throw APIError.needLogin }
            if missingStatuses.contains(status) { return JSON(nil) }
            if status == 429 {
                guard !waits.isEmpty else { throw APIError.busy }
                try await Task.sleep(nanoseconds: waits.removeFirst() * 1_000_000_000)
                continue
            }
            let value = JSON.parse(answer.0)
            if !(200..<300).contains(status) {
                let name = value["error"]["name"].string ?? value["result"]["message"].string ?? "ошибка"
                Log.shared.add("api: \(parts.path): \(status) \(name)")
                throw APIError.server("Яндекс ответил \(status): \(name)")
            }
            if !value.exists,
               String(data: answer.0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                return JSON([:])
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
        var catalog = false
        if let fields = source.dict, let id = source["id"].idText, let patched = Uncensor.shared.patch(track: fields, id: id) {
            value = JSON(patched.fields)
            uncensored = patched.file
            catalog = patched.catalog
        }
        guard let id = value["id"].idText, let title = value["title"].string else { return nil }
        let artists = value["artists"].array.map(Uncensor.shared.patch(artist:)).compactMap { artist -> ArtistRef? in
            guard let name = artist["name"].string else { return nil }
            return ArtistRef(id: artist["id"].idText ?? "", name: name)
        }
        var album = value["albums"][0]
        if let fields = album.dict, let albumID = album["id"].idText,
           let patch = Uncensor.shared.patch(album: fields, id: albumID) {
            album = JSON(patch)
        }
        let cover = value["coverUri"].string ?? album["coverUri"].string ?? album["cover"]["uri"].string
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
            mixFade: value["type"].string == "music" ? FadePoints.parse(value["mixFade"]) : nil,
            ugc: value["trackSource"].string.map { $0 == "UGC" },
            yandexAvailable: source["available"].bool,
            catalog: catalog ? true : nil)
    }

    private static func parsePlaylist(_ value: JSON, owner: String) -> Playlist? {
        guard let kind = value["kind"].idText, let title = value["title"].string else { return nil }
        let cover = value["coverUri"].string ?? value["cover"]["uri"].string ?? value["cover"]["itemsUri"][0].string ?? value["ogImage"].string
        return Playlist(
            owner: value["owner"]["uid"].idText ?? value["uid"].idText ?? owner,
            kind: kind,
            title: title,
            count: value["trackCount"].int ?? 0,
            cover: (cover?.isEmpty ?? true) ? nil : cover)
    }

    static func catalogPlaylistCard(kind: String, fields: [String: Any]) -> Playlist? {
        guard let title = fields["title"] as? String, !title.isEmpty else { return nil }
        let count = CatalogIndex.idList(fields["tracks"]).count
        let rawCover = (fields["coverUri"] as? String) ?? (fields["cover"] as? [String: Any])?["uri"] as? String
        let cover = (rawCover?.isEmpty ?? true) ? nil : rawCover
        return Playlist(owner: TuneCatalogID.owner, kind: kind, title: title, count: count, cover: cover)
    }

    private static func albumCard(_ source: JSON) -> Card? {
        var value = source
        if let fields = source.dict, let id = source["id"].idText, let patched = Uncensor.shared.patch(album: fields, id: id) {
            value = JSON(patched)
        }
        guard let id = value["id"].idText, let title = value["title"].string else { return nil }
        var subtitle = value["artists"].array.map(Uncensor.shared.patch(artist:)).compactMap { $0["name"].string }.joined(separator: ", ")
        if let year = value["year"].int {
            subtitle = subtitle.isEmpty ? "\(year)" : "\(subtitle) · \(year)"
        }
        return Card(id: id, title: title, subtitle: subtitle, cover: value["coverUri"].string ?? value["cover"]["uri"].string,
                    kind: value["type"].string)
    }

    /// Новинка с главной: альбом и исполнители лежат рядом.
    private static func releaseCard(_ value: JSON) -> Card? {
        guard var fields = value["album"].dict else { return nil }
        if fields["artists"] == nil { fields["artists"] = value["artists"].array.compactMap(\.dict) }
        guard var card = albumCard(JSON(fields)) else { return nil }
        if card.cover == nil { card.cover = value["cover"]["uri"].string }
        return card
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
        return .wave(WaveCard(title: title, seeds: seeds, cover: cover, color: data["colors"]["average"].string ?? data["agent"]["cover"]["color"].string))
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

    private static func artistCard(_ source: JSON) -> Card? {
        let value = Uncensor.shared.patch(artist: source)
        guard let id = value["id"].idText, let name = value["name"].string else { return nil }
        let cover = value["coverUri"].string ?? value["cover"]["uri"].string ?? value["ogImage"].string
        return Card(id: id, title: name, subtitle: "Исполнитель", cover: (cover?.isEmpty ?? true) ? nil : cover)
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
        try await likedEntries(uid: uid).map(\.id)
    }

    func likedEntries(uid: String) async throws -> [(id: String, addedAt: Date?)] {
        if Demo.on { return Demo.data.tracks.enumerated().map { ($0.element.id, Date(timeIntervalSince1970: Double($0.offset))) } }
        let localEntries: [(id: String, addedAt: Date?)] = CatalogLibraryStore.shared.likedTracks.map { ($0, nil) }
        func merging(_ remote: [(id: String, addedAt: Date?)]) -> [(id: String, addedAt: Date?)] {
            var seen = Set<String>()
            return (localEntries + remote).filter { seen.insert($0.id).inserted }
        }
        do {
            return merging(try await fullLikedEntries())
        } catch {
            try Task.checkCancellation()
        }
        let value = result(try await get("users/\(uid)/likes/tracks"))
        let parseDate = Self.listDateParser()
        let remote = value["library"]["tracks"].array.compactMap { item in
            item["id"].idText.map { ($0, parseDate(item["timestamp"])) }
        }
        return merging(remote)
    }

    func fullLikedEntries() async throws -> [(id: String, addedAt: Date?)] {
        let value = result(try await post("collection/sync", json: ["likedTracks": ["revision": 0]]))
        let entries = value["values"]["likedTracks"]["values"]["liked"]
        guard entries.isArray else { throw APIError.server("Яндекс не прислал полный список лайков") }
        let parseDate = Self.listDateParser()
        return entries.array.compactMap { item in
            guard let id = item["trackId"].idText ?? item["id"].idText else { return nil }
            return (id, parseDate(item["timestamp"]))
        }
    }

    private static func listDateParser() -> (JSON) -> Date? {
        let standard = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return { value in
            guard let date = value.string, !date.isEmpty else { return nil }
            return fractional.date(from: date) ?? standard.date(from: date)
        }
    }

    func setLiked(uid: String, track: String, liked: Bool) async throws {
        if Demo.on { return }
        if TuneCatalogID.isSyntheticTrack(track) {
            CatalogLibraryStore.shared.setTrackLiked(track, liked)
            return
        }
        let encoded = Self.encode(track)
        let path = liked ? "users/\(uid)/likes/tracks/add?track-id=\(encoded)" : "users/\(uid)/likes/tracks/\(encoded)/remove"
        let value = result(try await post(path))
        if value["revision"].exists { return }
        // Успешное изменение иногда возвращается без номера ревизии.
        let ids = try await likedIds(uid: uid)
        guard ids.contains(track) == liked else { throw APIError.server("Яндекс не сохранил отметку") }
    }

    /// Сведения о треках в том же порядке, что и номера.
    func tracks(ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        if Demo.on { return Demo.data.tracks.filter { ids.contains($0.id) } }
        let yandexIDs = ids.filter { !TuneCatalogID.isSyntheticTrack($0) }
        if yandexIDs.isEmpty {
            return ids.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
        }
        let value: JSON
        do {
            value = try await post("tracks", form: "track-ids=" + yandexIDs.map(Self.encode).joined(separator: "%2C"))
        } catch {
            try Task.checkCancellation()
            let local = ids.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
            if local.count != ids.count { throw error }
            return local
        }
        var found: [String: Track] = [:]
        for track in value["result"].array.compactMap(Self.parseTrack) where found[track.id] == nil {
            found[track.id] = track
        }
        return ids.compactMap { id in
            found[id] ?? Uncensor.shared.catalogTrack(id).flatMap(Self.parseTrack)
        }
    }

    func playlists(uid: String) async throws -> [Playlist] {
        if Demo.on { return Demo.data.playlists }
        let value = try await get("users/\(uid)/playlists/list")
        return value["result"].array.compactMap { Self.parsePlaylist($0, owner: uid) }.map { playlist in
            var copy = playlist
            copy.count += CatalogLibraryStore.shared.playlistTracks(owner: playlist.owner, kind: playlist.kind).count
            return copy
        }
    }

    func playlistTracks(_ playlist: Playlist) async throws -> [Track] {
        try await self.playlist(playlist).tracks
    }

    func playlist(_ playlist: Playlist) async throws -> PlaylistPage {
        if Demo.on {
            let tracks = Demo.data.tracks.enumerated().map { index, track in
                var track = track
                track.addedAt = Date(timeIntervalSince1970: Double(index))
                return track
            }
            return PlaylistPage(tracks: tracks, author: "Демо", about: "Музыка в дорогу: от спокойного к бодрому, чтобы не уснуть за рулём.")
        }
        if playlist.owner == TuneCatalogID.owner {
            guard let (fields, trackIDs) = Uncensor.shared.catalogPlaylist(playlist.kind) else {
                throw APIError.server("Плейлист не найден в каталоге Tune")
            }
            let tracks = try await self.tracks(ids: trackIDs)
            let rawCover = (fields["coverUri"] as? String) ?? (fields["cover"] as? [String: Any])?["uri"] as? String
            let cover = (rawCover?.isEmpty ?? true) ? playlist.cover : rawCover
            return PlaylistPage(
                tracks: tracks,
                author: fields["author"] as? String ?? "Каталог Tune",
                about: fields["description"] as? String ?? "",
                title: fields["title"] as? String ?? playlist.title,
                cover: cover,
                open: true)
        }
        let value = result(try await get("users/\(playlist.owner)/playlists/\(playlist.kind)", [("rich-tracks", "true")]))
        let parseDate = Self.listDateParser()
        let remoteTracks: [Track] = value["tracks"].array.compactMap { entry in
            guard var track = Self.parseTrack(entry["track"]) else { return nil }
            track.addedAt = parseDate(entry["timestamp"])
            return track
        }
        let localIDs = CatalogLibraryStore.shared.playlistTracks(owner: playlist.owner, kind: playlist.kind)
        let mergedTracks: [Track]
        if localIDs.isEmpty {
            mergedTracks = remoteTracks
        } else {
            let localTracks = (try? await self.tracks(ids: localIDs)) ?? localIDs.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
            var seen = Set<String>()
            mergedTracks = (localTracks + remoteTracks).filter { seen.insert($0.id).inserted }
        }
        return PlaylistPage(
            tracks: mergedTracks,
            author: value["owner"]["name"].string ?? "",
            about: value["description"].string ?? "",
            title: value["title"].string ?? "",
            cover: Self.parsePlaylist(value, owner: playlist.owner)?.cover,
            open: value["visibility"].string.map { $0 == "public" })
    }

    // MARK: - Альбомы, исполнители, поиск

    func album(id: String) async throws -> AlbumPage {
        if Demo.on {
            let all = Demo.data.albums + Demo.data.releases + Demo.podcasts
            guard let card = all.first(where: { $0.id == id }) ?? all.first else { throw APIError.server("Нет демо-данных") }
            var page = AlbumPage(card: card, year: 2024, tracks: Demo.data.tracks)
            page.artist = Demo.data.artists.first.map { ArtistRef(id: $0.id, name: $0.title) }
            page.label = "Warner Records"
            page.genre = "rock"
            page.disks = [8, max(1, Demo.data.tracks.count - 8)]
            page.versions = Array(all.filter { $0.id != card.id }.prefix(2))
            return page
        }
        var value: JSON
        if TuneCatalogID.isSyntheticAlbum(id) {
            guard let local = Uncensor.shared.catalogAlbum(id) else { throw APIError.server("Альбом не найден") }
            value = local
        } else {
            do {
                let remote = result(try await get("albums/\(id)/with-tracks"))
                if remote["error"].exists || remote["id"].idText == nil {
                    guard let local = Uncensor.shared.catalogAlbum(id) else { throw APIError.server("Альбом не найден") }
                    value = local
                } else {
                    value = remote
                }
            } catch {
                try Task.checkCancellation()
                guard let local = Uncensor.shared.catalogAlbum(id) else { throw error }
                value = local
            }
        }
        var disks: [[Track]] = value["volumes"].array.map { $0.array.compactMap(Self.parseTrack) }
        // Без цензуры: треки по дискам, как в списке FckCensor, с удалёнными Яндексом.
        if let want = Uncensor.shared.volumes(album: id) {
            var have: [String: Track] = [:]
            for track in disks.flatMap({ $0 }) { have[track.id] = track }
            let missing = want.flatMap { $0 }.filter { have[$0] == nil }
            if !missing.isEmpty {
                let extra = try? await tracks(ids: missing)
                try Task.checkCancellation()
                let restored = missing.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
                for track in restored { have[track.id] = track }
                for track in extra ?? [] { have[track.id] = track }
            }
            var listed = Set<String>()
            var rebuilt: [[Track]] = want.map { disk in
                disk.compactMap { id -> Track? in
                    listed.insert(id)
                    return have[id]
                }
            }
            let rest = disks.flatMap { $0 }.filter { !listed.contains($0.id) }
            if !rest.isEmpty, Uncensor.shared.customDisks(album: id) == nil { rebuilt.append(rest) }
            disks = rebuilt
        }
        guard let card = Self.albumCard(value) else { throw APIError.server("Яндекс не прислал альбом") }
        var page = AlbumPage(card: card, year: value["year"].int, tracks: disks.flatMap { $0 })
        if let fields = value.dict, let patch = Uncensor.shared.patch(album: fields, id: id) { value = JSON(patch) }
        let artist = Uncensor.shared.patch(artist: value["artists"][0])
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
        let yandexIDs = ids.filter { !TuneCatalogID.isSyntheticAlbum($0) }
        if yandexIDs.isEmpty {
            return ids.compactMap(Uncensor.shared.catalogAlbum).compactMap(Self.albumCard)
        }
        do {
            let value = try await post("albums", form: "album-ids=" + yandexIDs.map(Self.encode).joined(separator: "%2C"))
            let cards = value["result"].array.compactMap(Self.albumCard)
            let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] ?? Uncensor.shared.catalogAlbum($0).flatMap(Self.albumCard) }
        } catch {
            try Task.checkCancellation()
            let restored = ids.compactMap(Uncensor.shared.catalogAlbum).compactMap(Self.albumCard)
            if restored.isEmpty { throw error }
            return restored
        }
    }

    private func catalogArtistPage(id: String) async -> ArtistPage? {
        guard let (raw, trackIDs, albumIDs) = Uncensor.shared.catalogArtist(id) else { return nil }
        let popular = (try? await tracks(ids: trackIDs)) ?? trackIDs.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
        let cards = (try? await albums(ids: albumIDs)) ?? albumIDs.compactMap(Uncensor.shared.catalogAlbum).compactMap(Self.albumCard)
        let albums = cards.filter { $0.kind != "single" }
        let singles = cards.filter { $0.kind == "single" }
        let name = raw["name"].string ?? "Без имени"
        let cover = raw["coverUri"].string ?? raw["cover"]["uri"].string ?? raw["ogImage"].string
        let about = raw["description"].string ?? raw["description"]["text"].string ?? ""
        var page = ArtistPage(
            id: id, name: name, cover: (cover?.isEmpty ?? true) ? nil : cover,
            popular: popular, albums: albums, also: [], similar: [])
        page.singles = singles
        page.about = about
        page.latestRelease = cards.first
        page.clips = []
        page.concerts = []
        return page
    }

    func artist(id: String, includeExtras: Bool = false) async throws -> ArtistPage {
        if Demo.on {
            guard let card = Demo.data.artists.first(where: { $0.id == id }) ?? Demo.data.artists.first else { throw APIError.server("Нет демо-данных") }
            var page = ArtistPage(id: card.id, name: card.title, cover: card.cover, popular: Demo.data.tracks, albums: Demo.data.albums, similar: Demo.data.artists)
            page.singles = Demo.data.releases
            page.latestRelease = Demo.data.releases.first
            page.playlists = Demo.data.playlists
            page.listeners = 12_400_000
            page.about = "Британская рок-группа, добившаяся широчайшей известности в середине 1970-х годов, и одна из наиболее успешных групп в истории рок-музыки."
            return page
        }
        if TuneCatalogID.isSyntheticArtist(id) {
            guard let page = await catalogArtistPage(id: id) else { throw APIError.server("Исполнитель не найден") }
            return page
        }
        let value: JSON
        do {
            value = result(try await get("artists/\(id)/brief-info"))
        } catch {
            try Task.checkCancellation()
            if let page = await catalogArtistPage(id: id) { return page }
            throw error
        }
        let artist = Uncensor.shared.patch(artist: value["artist"])
        guard let name = artist["name"].string, artist["error"].string != "not-found" else {
            if let page = await catalogArtistPage(id: id) { return page }
            throw APIError.server("Исполнитель не найден")
        }
        async let clips = includeExtras ? artistClips(id, legacy: value["videos"]) : []
        async let concerts = includeExtras ? artistConcerts(id) : []
        var popular = value["popularTracks"].array.compactMap(Self.parseTrack)
        let releases = value["albums"].array
        var albums = releases.filter { $0["type"].string != "single" }.compactMap(Self.albumCard)
        var singles = releases.filter { $0["type"].string == "single" }.compactMap(Self.albumCard)
        let playlists = value["playlists"].array.compactMap { item -> Playlist? in
            guard let owner = item["uid"].idText ?? item["owner"]["uid"].idText else { return nil }
            return Self.parsePlaylist(item, owner: owner)
        }
        // Добавленные в профиль треки — в начало популярных, альбомы — в начало альбомов.
        let inserts = Uncensor.shared.inserts(artist: id)
        popular = await mergeArtistTracks(popular, restoredIDs: inserts.tracks)
        if let extra = try? await self.albums(ids: inserts.albums) {
            let known = Set((albums + singles).map(\.id))
            let added = extra.filter { !known.contains($0.id) }
            albums.insert(contentsOf: added.filter { $0.kind != "single" }, at: 0)
            singles.insert(contentsOf: added.filter { $0.kind == "single" }, at: 0)
        }
        var page = ArtistPage(
            id: id, name: name, cover: artist["coverUri"].string ?? artist["cover"]["uri"].string ?? artist["ogImage"].string, popular: popular, albums: albums,
            also: value["alsoAlbums"].array.compactMap(Self.albumCard), similar: value["similarArtists"].array.compactMap(Self.artistCard))
        page.singles = singles
        page.playlists = playlists
        page.listeners = value["stats"]["lastMonthListeners"].int
        page.about = artist["description"]["text"].string ?? ""
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        page.latestRelease = value["lastReleases"].array.compactMap(Self.albumCard).first ?? releases.compactMap { release -> (String, Card)? in
            guard let stamp = release["releaseDate"].string, stamp.count >= 10,
                  let card = Self.albumCard(release) else { return nil }
            let day = String(stamp.prefix(10))
            return day <= today ? (day, card) : nil
        }.max { $0.0 < $1.0 }?.1
        page.clips = await clips
        page.concerts = await concerts
        return page
    }

    func artistCover(id: String) async throws -> String? {
        if Demo.on { return Demo.data.artists.first { $0.id == id }?.cover }
        if TuneCatalogID.isSyntheticArtist(id) {
            return Uncensor.shared.catalogArtist(id).flatMap { Self.artistCard($0.json)?.cover }
        }
        let value = result(try await get("artists/\(id)/brief-info"))
        return Self.artistCard(value["artist"])?.cover
    }

    private func artistClips(_ id: String, legacy: JSON) async -> [ArtistClip] {
        let value = (try? await get("artists/\(id)/blocks/artist-clips", [("page", "0"), ("pageSize", "30")])).map(result)
        let found = value?["items"].array.compactMap { item -> ArtistClip? in
            let clip = item["data"]["clip"].isObject ? item["data"]["clip"] : item
            guard clip["contentRestrictions"]["available"].bool != false,
                  let id = clip["clipId"].idText ?? clip["id"].idText, !id.isEmpty,
                  let title = clip["title"].string, !title.isEmpty else { return nil }
            var address = URLComponents(string: "https://music.yandex.ru/video")
            address?.queryItems = [URLQueryItem(name: "ids", value: id)]
            guard let url = address?.url else { return nil }
            return ArtistClip(id: id, title: title, cover: clip["thumbnail"].string ?? clip["cover"]["uri"].string, url: url,
                              playerID: clip["playerId"].string)
        } ?? []
        var seen = Set<String>()
        if !found.isEmpty { return found.filter { seen.insert($0.id).inserted } }
        return legacy.array.compactMap { video in
            guard let title = video["title"].string, !title.isEmpty,
                  let raw = video["embedUrl"].string, let url = URL(string: raw),
                  url.scheme == "https", url.host != nil, seen.insert(raw).inserted else { return nil }
            let playerID = url.host == "frontend.vh.yandex.ru" ? video["providerVideoId"].idText : nil
            return ArtistClip(id: raw, title: title, cover: video["cover"].string, url: url, playerID: playerID)
        }
    }

    private func artistConcerts(_ id: String) async -> [ArtistConcert] {
        guard let response = try? await get("artists/\(id)/blocks/artist-concerts") else { return [] }
        return Self.parseConcerts(result(response)["concerts"].array)
    }

    func concertCities() async throws -> [ConcertCity] {
        if Demo.on { return [ConcertCity(id: "213", name: "Москва"), ConcertCity(id: "2", name: "Санкт-Петербург")] }
        let value = result(try await get("concerts/locations"))
        var seen = Set<String>()
        return value["locations"].array.compactMap { item in
            guard let id = item["id"].idText, let name = item["name"].string, seen.insert(id).inserted else { return nil }
            return ConcertCity(id: id, name: name)
        }
    }

    func concerts(city: String?) async throws -> [ArtistConcert] {
        if Demo.on {
            return [ArtistConcert(id: "demo-concert", title: "Симфонический концерт",
                                  city: city == "2" ? "Санкт-Петербург" : "Москва", venue: "Филармония",
                                  date: "2026-12-05T19:00:00+03:00", cover: nil, tickets: nil)]
        }
        let value = result(try await get("concerts/feed", city.map { [("locations", $0)] } ?? []))
        return Self.parseConcerts(value["items"].array.filter { $0["type"].string == "concert_item" }.map { $0["data"] })
    }

    private static func parseConcerts(_ items: [JSON]) -> [ArtistConcert] {
        var seen = Set<String>()
        return items.compactMap { item in
            let concert = item["concert"]
            guard let id = concert["id"].idText, seen.insert(id).inserted,
                  let title = concert["concertTitle"].string, !title.isEmpty else { return nil }
            let tickets = concert["dataSessionId"].string.flatMap { session -> URL? in
                guard !session.isEmpty, session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
                var url = URLComponents(string: "https://widget.afisha.yandex.ru/w/sessions/\(session)")
                url?.queryItems = [URLQueryItem(name: "clientKey", value: "0d8ab1a6-1667-42cb-a98f-2fe7eff4b137")]
                return url?.url
            }
            return ArtistConcert(id: id, title: title, city: concert["city"].string ?? "", venue: concert["place"].string ?? "",
                                 date: concert["datetime"].string ?? "", cover: concert["cover"]["uri"].string, tickets: tickets)
        }
    }

    func clipStream(_ clip: ArtistClip) async throws -> URL {
        guard let token = TokenStore.token else { throw APIError.needLogin }
        var identifier = clip.playerID
        if identifier == nil, clip.url.host == "music.yandex.ru" {
            let value = result(try await get("clips", [("clipIds", clip.id)]))
            let items = value.isArray ? value.array : value["clips"].array
            identifier = items.first?["playerId"].string
        }
        guard let identifier, !identifier.isEmpty,
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0) }) else {
            throw APIError.server("Яндекс не прислал адрес клипа")
        }
        var address = URLComponents()
        address.scheme = "https"
        address.host = "frontend.vh.yandex.ru"
        address.path = "/player/\(identifier).json"
        address.queryItems = [URLQueryItem(name: "service", value: "ya-music"), URLQueryItem(name: "from", value: "ya-music")]
        guard let url = address.url else { throw APIError.server("Не удалось открыть клип") }
        var request = URLRequest(url: url)
        request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.yandex.ru", forHTTPHeaderField: "Origin")
        request.setValue("https://music.yandex.ru/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.data(for: request)
        let value = JSON.parse(data)
        if value["error"].string == "no_licenses" { throw APIError.server("Клип недоступен в вашем регионе") }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let raw = value["content"]["streams"].array.first(where: { $0["stream_type"].string == "HLS" })?["url"].string,
              let stream = URL(string: raw), stream.scheme == "https", stream.host != nil else {
            throw APIError.server("Яндекс не прислал видео для плеера")
        }
        return stream
    }

    func artistTracks(id: String) async throws -> [Track] {
        if Demo.on { return Demo.data.tracks }
        if TuneCatalogID.isSyntheticArtist(id) {
            guard let (_, trackIDs, _) = Uncensor.shared.catalogArtist(id) else {
                throw APIError.server("Исполнитель не найден")
            }
            return (try? await tracks(ids: trackIDs)) ?? trackIDs.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
        }
        let restoredIDs = Uncensor.shared.inserts(artist: id).tracks
        do {
            let value = result(try await get("artists/\(id)/tracks", [("page-size", "200")]))
            return await mergeArtistTracks(value["tracks"].array.compactMap(Self.parseTrack), restoredIDs: restoredIDs)
        } catch {
            try Task.checkCancellation()
            let restored = restoredIDs.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
            if restored.isEmpty { throw error }
            return restored
        }
    }

    func trackFilters(ids: [String]) async throws -> [TrackFilter] {
        if Demo.on { return [] }
        var seen = Set<String>()
        let catalogIds = ids.filter {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && !TuneCatalogID.isSyntheticTrack($0) && seen.insert($0).inserted
        }
        guard catalogIds.count >= 4 else { return [] }
        let value = result(try await post("filters/tracks", json: ["trackIds": catalogIds]))
        let parsed: [TrackFilter] = value["filters"].array.compactMap { item in
            guard let id = item["id"].string, let name = item["name"].string else { return nil }
            let trackIds = Set(item["tracks"].array.compactMap(\.idText))
            return TrackFilter(id: id, name: name, trackIds: trackIds)
        }
        return TrackFilter.select(parsed, catalogIds: Set(catalogIds))
    }

    private func mergeArtistTracks(_ remote: [Track], restoredIDs: [String]) async -> [Track] {
        let known = Set(remote.map(\.id))
        let missing = restoredIDs.filter { !known.contains($0) }
        let local = missing.compactMap(Uncensor.shared.catalogTrack).compactMap(Self.parseTrack)
        let localIDs = Set(local.map(\.id))
        let unresolved = missing.filter { !localIDs.contains($0) }
        let extra = (try? await tracks(ids: unresolved)) ?? []
        return local + extra + remote
    }

    func familiarTracks(artist id: String, wave: Bool) async throws -> [Track] {
        if Demo.on { return Array(Demo.data.tracks.prefix(wave ? 4 : 6)) }
        if TuneCatalogID.isSyntheticArtist(id) {
            return await Self.familiarOnDevice(artist: id, wave: wave)
        }
        let kind = wave ? "wave" : "collection"
        let query = [("waveTracksLimit", wave ? "50" : "0"),
                     ("collectionTracksLimit", wave ? "0" : "50"), ("collectionAlbumsLimit", "0")]
        let remote: [Track]
        do {
            let response = result(try await get("artists/\(id)/familiar-you", query))
            remote = response[kind]["tracks"].array.compactMap { entry in
                let track = entry["track"].isObject ? entry["track"] : entry
                let id = track["id"].idText ?? entry["trackId"].idText ?? entry.idText
                return Self.parseTrack(track) ?? id.flatMap(Uncensor.shared.catalogTrack).flatMap(Self.parseTrack)
            }
        } catch {
            try Task.checkCancellation()
            let local = await Self.familiarOnDevice(artist: id, wave: wave)
            if local.isEmpty { throw error }
            return local
        }
        let local = await Self.familiarOnDevice(artist: id, wave: wave)
        var seen = Set<String>()
        return (remote + local).filter { seen.insert($0.id).inserted }
    }

    @MainActor
    private static func familiarOnDevice(artist id: String, wave: Bool) -> [Track] {
        let session = Session.shared
        let catalogIDs = Uncensor.shared.inserts(artist: id).tracks
        let catalogSet = Set(catalogIDs)
        func belongs(_ track: Track) -> Bool {
            catalogSet.contains(track.id) || track.artistList.contains { $0.id == id }
        }
        if wave {
            guard let uid = session.profile?.uid else { return [] }
            return Stats.shared.recentRestoredWaveTracks(account: uid).filter(belongs)
        }
        let localLikes = session.localLikedTracks.filter(belongs)
        let annotated = catalogIDs.compactMap { trackID -> Track? in
            guard let value = Uncensor.shared.catalogTrack(trackID), let track = parseTrack(value),
                  session.isLiked(trackID) || track.albumId.map(session.likedAlbums.contains) == true else { return nil }
            return track
        }
        var seen = Set<String>()
        return (localLikes + annotated).filter { seen.insert($0.id).inserted }
    }

    /// Подсказки: как Яндекс предлагает закончить запрос.
    func suggest(_ text: String) async throws -> [String] {
        if Demo.on { return ["queen bohemian rhapsody", "queen of the damned", "queens of the stone age", "queencard"] }
        let value = result(try await get("search/suggest", [("part", text)]))
        return value["suggestions"].array.compactMap { $0.string }
    }

    func search(_ text: String, types: String, filter: String?, page: Int, size: Int) async throws -> SearchResult {
        if Demo.on {
            return Demo.search(types: types, filter: filter, page: page, size: size)
        }
        var query = [("text", text), ("type", types), ("page", "\(page)"), ("pageSize", "\(size)")]
        if let filter { query.append(("filter", filter)) }
        let types = Set(types.split(separator: ","))
        var local = SearchResult()
        if page == 0, filter == nil {
            let matches = Uncensor.shared.search(
                text,
                tracks: types.contains("track"),
                albums: types.contains("album"),
                artists: types.contains("artist"),
                playlists: types.contains("playlist")
            )
            local.tracks = matches.tracks.compactMap(Self.parseTrack).filter { $0.uncensored || $0.isCatalog }
            local.albums = matches.albums.compactMap(Self.albumCard)
            local.artists = matches.artists.compactMap(Self.artistCard)
            local.playlists = matches.playlists.compactMap { Self.catalogPlaylistCard(kind: $0.kind, fields: $0.fields) }
            local.best = local.tracks.first.map { .track($0) }
                ?? local.albums.first.map { .album($0) }
                ?? local.artists.first.map { .artist($0) }
                ?? local.playlists.first.map { .playlist($0) }
        }
        let value: JSON
        do {
            value = result(try await get("search/instant/mixed", query))
            guard value["results"].isArray else { throw APIError.server("Яндекс не прислал результаты поиска") }
        } catch {
            try Task.checkCancellation()
            if local.isEmpty { throw error }
            return local
        }
        var found = SearchResult()
        found.hasMore = value["lastPage"].bool == false && !value["results"].array.isEmpty
        // Результаты идут по убыванию точности: первый из них и есть лучший.
        for item in value["results"].array {
            switch item["type"].string {
            case "track":
                if let track = Self.parseTrack(item["track"]) {
                    if found.best == nil { found.best = .track(track) }
                    if filter == "podcast" { found.episodes.append(track) } else { found.tracks.append(track) }
                }
            case "album":
                if let card = Self.albumCard(item["album"]) {
                    if filter == "podcast", item["album"]["type"].string == "podcast" {
                        if found.best == nil { found.best = .podcast(card) }
                        found.podcasts.append(card)
                    } else {
                        if found.best == nil { found.best = .album(card) }
                        found.albums.append(card)
                    }
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
            case "podcast":
                if var card = Self.albumCard(item["podcast"]) {
                    if card.subtitle.isEmpty { card.subtitle = "Подкаст" }
                    if found.best == nil { found.best = .podcast(card) }
                    found.podcasts.append(card)
                }
            case "podcast_episode":
                if let track = Self.parseTrack(item["podcast_episode"]) {
                    if found.best == nil { found.best = .track(track) }
                    found.episodes.append(track)
                }
            default:
                break
            }
        }
        // Если Яндекс тоже нашёл запись, сохраняем её полные метаданные.
        let remoteTracks = Set(found.tracks.map(\.id))
        let remoteAlbums = Set(found.albums.map(\.id))
        let remoteArtists = Set(found.artists.map(\.id))
        let remotePlaylists = Set(found.playlists.map(\.id))
        local.tracks.removeAll { remoteTracks.contains($0.id) }
        local.albums.removeAll { remoteAlbums.contains($0.id) }
        local.artists.removeAll { remoteArtists.contains($0.id) }
        local.playlists.removeAll { remotePlaylists.contains($0.id) }
        let localBest = local.tracks.first.map { SearchBest.track($0) }
            ?? local.albums.first.map { SearchBest.album($0) }
            ?? local.artists.first.map { SearchBest.artist($0) }
            ?? local.playlists.first.map { SearchBest.playlist($0) }
        var unique = SearchResult(best: Self.preferredBest(query: text, remote: found.best, local: localBest))
        unique.append(local)
        unique.append(found)
        return unique
    }

    private static func searchTokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func bestTokens(_ item: SearchBest) -> [String] {
        switch item {
        case .track(let track):
            return searchTokens(track.title) + searchTokens(track.artists) + searchTokens(track.albumTitle)
        case .artist(let card), .album(let card), .podcast(let card):
            return searchTokens(card.title) + searchTokens(card.subtitle)
        case .playlist(let playlist):
            return searchTokens(playlist.title)
        }
    }

    private static func bestExactTitle(_ item: SearchBest, terms: [String]) -> Bool {
        switch item {
        case .track(let track): return searchTokens(track.title) == terms
        case .artist(let card), .album(let card), .podcast(let card): return searchTokens(card.title) == terms
        case .playlist(let playlist): return searchTokens(playlist.title) == terms
        }
    }

    private static func preferredBest(query: String, remote: SearchBest?, local: SearchBest?) -> SearchBest? {
        guard let local else { return remote }
        guard let remote else { return local }
        let terms = searchTokens(query)
        guard !terms.isEmpty else { return remote }
        let allowPrefix = terms.reduce(0) { $0 + $1.count } >= 3
        let tokens = bestTokens(remote)
        let remoteMatchesAll = terms.allSatisfy { term in
            allowPrefix ? tokens.contains { $0.hasPrefix(term) } : tokens.contains(term)
        }
        if !remoteMatchesAll { return local }
        if bestExactTitle(local, terms: terms) && !bestExactTitle(remote, terms: terms) { return local }
        return remote
    }

    /// Последний доступный текст, в том числе сохранённый ранними версиями Tune.
    private static func savedLyrics(for track: Track) -> LyricsText? {
        let name = "Lyrics/\(Storage.hash(track.id)).json"
        var saved = Storage.load(name, as: LyricsText.self)
        if saved == nil, let lines = Storage.load(name, as: [LyricLine].self) {
            saved = LyricsText(lines: lines, authors: nil, source: LyricsText.yandex)
        }
        if let saved, !saved.lines.isEmpty, !isStub(saved.lines) { return saved }
        return nil
    }

    static func hasSavedLyrics(for track: Track) -> Bool {
        savedLyrics(for: track) != nil
    }

    static func cachedLyrics(for track: Track, anySource: Bool = false) -> LyricsText? {
        guard let saved = savedLyrics(for: track) else { return nil }
        return ExternalLyrics.acceptCached(saved, anySource: anySource)
    }

    /// Текст, вшитый прямо в локальный или скачанный аудиофайл (ID3/MP4).
    static func embeddedLyrics(for trackID: String) async -> LyricsText? {
        var urls: [URL] = []
        if let url = Uncensor.shared.localAudio(trackID) { urls.append(url) }
        if let url = await Downloads.shared.fileURL(for: trackID) { urls.append(url) }
        if let url = TrackFiles.existing(id: TrackFiles.Version.uncensored.cacheID(trackID), in: Storage.stream) {
            urls.append(url)
        }
        if let url = TrackFiles.existing(id: trackID, in: Storage.stream) {
            urls.append(url)
        }
        for url in urls {
            let asset = AVURLAsset(url: url)
            if let raw = (try? await asset.load(.lyrics)) ?? nil,
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lines = ExternalLyrics.parseLRC(raw)
                if lines.contains(where: { !$0.text.isEmpty }) {
                    return LyricsText(lines: lines, authors: nil, source: nil)
                }
            }
        }
        return nil
    }

    static func searchSavedLyrics(_ text: String, in tracks: [Track]) -> [Track] {
        func words(_ text: String) -> String {
            ExternalLyrics.cleanWords(text)
        }
        let phrase = words(text)
        guard phrase.count >= 3 else { return [] }
        let needle = " \(phrase) "
        var seen = Set<String>()
        return tracks.filter { track in
            guard !Task.isCancelled, seen.insert(track.id).inserted,
                  let lyrics = savedLyrics(for: track) else { return false }
            return (" " + words(lyrics.lines.map(\.text).joined(separator: " ")) + " ").contains(needle)
        }
    }

    /// NetEase находит название по строке, Яндекс даёт доступный для воспроизведения трек.
    func searchTracksByLine(_ text: String) async throws -> [Track] {
        if Demo.on { return Demo.data.tracks.filter { _ in text == "Здесь звучит припев" } }
        let hits = try await ExternalLyrics.searchByLine(text)
        return await withTaskGroup(of: (Int, Track?).self) { group in
            for (index, hit) in hits.enumerated() {
                group.addTask {
                    let matches = try? await self.search("\(hit.artist) \(hit.title)", types: "track", filter: nil, page: 0, size: 12)
                    return (index, matches?.tracks.first { ExternalLyrics.matches($0, lyricHit: hit) })
                }
            }
            var tracks: [(Int, Track)] = []
            for await (index, track) in group {
                if let track { tracks.append((index, track)) }
            }
            var seen = Set<String>()
            return tracks.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0.id).inserted }
        }
    }

    /// Альбомы и исполнители, которые нравятся пользователю.
    func likedAlbums(uid: String) async throws -> [Card] {
        if Demo.on { return Demo.data.albums + Demo.podcasts.map { card in
            var podcast = card
            podcast.kind = "podcast"
            return podcast
        } }
        let local = CatalogLibraryStore.shared.likedAlbums.compactMap(Uncensor.shared.catalogAlbum).compactMap(Self.albumCard)
        let value = result(try await get("users/\(uid)/likes/albums", [("rich", "true")]))
        let remote = value.array.compactMap { Self.albumCard($0["album"]) }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0.id).inserted }
    }

    func likedArtists(uid: String) async throws -> [Card] {
        if Demo.on { return Demo.data.artists }
        let local = CatalogLibraryStore.shared.likedArtists.compactMap { Uncensor.shared.catalogArtist($0)?.json }.compactMap(Self.artistCard)
        let value = result(try await get("users/\(uid)/likes/artists", [("with-timestamps", "false")]))
        // Исполнитель приходит то сам по себе, то внутри artist.
        let remote = value.array.compactMap { Self.artistCard($0) ?? Self.artistCard($0["artist"]) }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0.id).inserted }
    }

    func topArtists() async throws -> [Card] {
        if Demo.on {
            return Demo.data.artists.enumerated().map { index, card in
                var top = card
                top.subtitle = "\(index + 1) место · \(max(1, 5 - index)) ч"
                return top
            }
        }
        let value = result(try await get("personal/top/artists/month"))
        return Self.parseTopArtists(value)
    }

    static func parseTopArtists(_ value: JSON) -> [Card] {
        value["artists"].array.compactMap { item -> Card? in
            guard var card = Self.artistCard(item["artist"]) else { return nil }
            let place = item["top"]["position"].idText.flatMap(Int.init).flatMap { $0 > 0 ? "\($0) место" : nil }
            let seconds = item["listenTimeSeconds"].double ?? item["listenTimeSeconds"].string.flatMap(Double.init) ?? 0
            let time = topListenTimeText(seconds)
            card.subtitle = [place, time].compactMap { $0 }.joined(separator: " · ")
            return card
        }
    }

    func dislikedArtists(uid: String) async throws -> [Card] {
        if Demo.on { return [] }
        let local = CatalogLibraryStore.shared.dislikedArtists.compactMap { Uncensor.shared.catalogArtist($0)?.json }.compactMap(Self.artistCard)
        let value = result(try await get("users/\(uid)/dislikes/artists"))
        let remote = value.array.compactMap { Self.artistCard($0["artist"]) ?? Self.artistCard($0) }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0.id).inserted }
    }

    func likedPlaylists(uid: String) async throws -> [Playlist] {
        if Demo.on { return Demo.data.personal }
        let local: [Playlist] = CatalogLibraryStore.shared.likedPlaylists.compactMap { kind in
            guard let (fields, _) = Uncensor.shared.catalogPlaylist(kind) else { return nil }
            return Self.catalogPlaylistCard(kind: kind, fields: fields)
        }
        let value = result(try await get("users/\(uid)/likes/playlists"))
        let remote = value.array.compactMap { item -> Playlist? in
            let playlist = item["playlist"].isObject ? item["playlist"] : item
            guard let owner = playlist["uid"].idText ?? playlist["owner"]["uid"].idText else { return nil }
            return Self.parsePlaylist(playlist, owner: owner)
        }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0.id).inserted }
    }

    /// Номера альбомов и исполнителей из коллекции и треков с дизлайком: по ним рисуются сердечки.
    func likedAlbumIds(uid: String) async throws -> [String] {
        if Demo.on { return [] }
        let local = CatalogLibraryStore.shared.likedAlbums
        let value = result(try await get("users/\(uid)/likes/albums"))
        let remote = value.array.compactMap { $0["id"].idText ?? $0["album"]["id"].idText }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0).inserted }
    }

    func likedArtistIds(uid: String) async throws -> [String] {
        if Demo.on { return [] }
        let local = CatalogLibraryStore.shared.likedArtists
        let value = result(try await get("users/\(uid)/likes/artists", [("with-timestamps", "false")]))
        let remote = value.array.compactMap { $0["id"].idText ?? $0["artist"]["id"].idText }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0).inserted }
    }

    func dislikedIds(uid: String) async throws -> [String] {
        if Demo.on { return [] }
        let local = CatalogLibraryStore.shared.dislikedTracks
        let value = result(try await get("users/\(uid)/dislikes/tracks"))
        let remote = value["library"]["tracks"].array.compactMap { $0["id"].idText }
        var seen = Set<String>()
        return (local + remote).filter { seen.insert($0).inserted }
    }

    /// Дизлайк: Яндекс больше не предложит этот трек.
    func setDisliked(uid: String, track: String, disliked: Bool) async throws {
        if TuneCatalogID.isSyntheticTrack(track) {
            CatalogLibraryStore.shared.setTrackDisliked(track, disliked)
            return
        }
        _ = try await post(disliked ? "users/\(uid)/dislikes/tracks/add?track-id=\(track)" : "users/\(uid)/dislikes/tracks/\(track)/remove")
    }

    /// kind — albums или artists, param — album-id или artist-id.
    func setLiked(uid: String, kind: String, param: String, id: String, liked: Bool) async throws {
        if kind == "albums", TuneCatalogID.isSyntheticAlbum(id) {
            CatalogLibraryStore.shared.setAlbumLiked(id, liked)
            return
        }
        if kind == "artists", TuneCatalogID.isSyntheticArtist(id) {
            CatalogLibraryStore.shared.setArtistLiked(id, liked)
            return
        }
        _ = try await post(liked ? "users/\(uid)/likes/\(kind)/add?\(param)=\(id)" : "users/\(uid)/likes/\(kind)/\(id)/remove")
    }

    func setLiked(uid: String, playlist: Playlist, liked: Bool) async throws {
        if playlist.owner == TuneCatalogID.owner {
            CatalogLibraryStore.shared.setPlaylistLiked(playlist.kind, liked)
            return
        }
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

    func changeUploadedTrack(id: String, title: String, artist: String) async throws {
        _ = try await post("ugc/tracks/\(Self.encode(id))/change", json: ["title": title, "artist": artist])
    }

    func uploadTrack(_ file: URL, to playlist: Playlist) async throws -> String {
        let hasAccess = file.startAccessingSecurityScopedResource()
        defer { if hasAccess { file.stopAccessingSecurityScopedResource() } }
        let name = file.lastPathComponent
        let query = [("uid", playlist.owner), ("playlist-id", "\(playlist.owner):\(playlist.kind)"), ("path", name)]
        let value = try await send("POST", "loader/upload-url", query: query, body: Data(),
                                   type: "application/x-www-form-urlencoded")
        if value["result"].string == "TOO_MANY_FILES" {
            throw APIError.server("Превышен лимит по количеству загруженных треков")
        }
        let place = value["post-target"].string == nil ? result(value) : value
        guard let raw = place["post-target"].string, let url = URL(string: raw),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              let id = place["ugc-track-id"].idText, !id.isEmpty else {
            throw APIError.server("Яндекс не дал ссылку для загрузки")
        }
        let boundary = "Tune-" + UUID().uuidString
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(boundary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.writeUploadBody(file: file, to: temporary, boundary: boundary)
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Signed upload URL. The account token stays with the Music API.
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: temporary)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 413 { throw APIError.server("Аудиофайл слишком большой") }
        guard (200..<300).contains(status) else { throw APIError.server("Ошибка загрузки аудиофайла (\(status))") }
        return id
    }

    private static func writeUploadBody(file: URL, to destination: URL, boundary: String) throws {
        let mime: String
        switch file.pathExtension.lowercased() {
        case "mp3": mime = "audio/mpeg"
        case "m4a", "aac": mime = "audio/mp4"
        case "flac": mime = "audio/flac"
        case "ogg", "opus": mime = "audio/ogg"
        case "wav": mime = "audio/wav"
        default: mime = "application/octet-stream"
        }
        let name = file.lastPathComponent.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\\", with: "%5C")
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n"
        try Data(header.utf8).write(to: destination)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    func readyUploads(_ ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let body = "track-ids=" + ids.map(Self.encode).joined(separator: "%2C") + "&withProgress=true"
        let value = result(try await post("tracks", form: body))
        return Set(value.array.filter { $0["state"].string == "playable" }.compactMap { $0["id"].idText })
    }

    func uploadPlaylistCover(_ playlist: Playlist, jpeg: Data) async throws -> String {
        let boundary = "Tune-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let path = "users/\(playlist.owner)/playlists/\(playlist.kind)/cover/upload"
        let value = result(try await send("POST", path, body: body, type: "multipart/form-data; boundary=\(boundary)"))
        if let cover = value["cover"]["uri"].string, !cover.isEmpty { return cover }
        if let cover = try await self.playlist(playlist).cover, !cover.isEmpty { return cover }
        throw APIError.server("Яндекс не вернул новую обложку")
    }

    /// «Меньше ИИ»: Яндекс реже ставит в рекомендации музыку, созданную с помощью ИИ.
    func aiReduction() async throws -> Bool {
        if Demo.on { return false }
        return result(try await get("account/settings"))["aiContentReductionEnabled"].bool ?? false
    }

    func setAIReduction(_ enabled: Bool) async throws {
        if Demo.on { return }
        _ = try await post("account/settings?aiContentReductionEnabled=\(enabled)")
    }

    func setPlaylistOpen(uid: String, kind: String, _ open: Bool) async throws {
        _ = try await post("users/\(uid)/playlists/\(kind)/visibility?value=\(open ? "public" : "private")")
    }

    func deletePlaylist(uid: String, kind: String) async throws {
        _ = try await post("users/\(uid)/playlists/\(kind)/delete")
        CatalogLibraryStore.shared.clearPlaylist(owner: uid, kind: kind)
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

    func addToPlaylist(uid: String, kind: String, tracks: [Track], atEnd: Bool = false) async throws {
        let synthetic = tracks.filter { TuneCatalogID.isSyntheticTrack($0.id) }
        let yandex = tracks.filter { !TuneCatalogID.isSyntheticTrack($0.id) }
        if !yandex.isEmpty {
            try await change(uid: uid, kind: kind) { state in
                [["op": "insert", "at": atEnd ? state["tracks"].array.count : 0, "tracks": yandex.map(Self.reference)]]
            }
        }
        if !synthetic.isEmpty {
            CatalogLibraryStore.shared.addPlaylistTracks(synthetic.map(\.id), owner: uid, kind: kind, atEnd: atEnd)
        }
    }

    func removeFromPlaylist(uid: String, kind: String, track: Track) async throws {
        if TuneCatalogID.isSyntheticTrack(track.id) {
            CatalogLibraryStore.shared.removePlaylistTrack(track.id, owner: uid, kind: kind)
            return
        }
        try await change(uid: uid, kind: kind) { state in
            guard let position = Self.position(of: track.id, in: state) else {
                throw APIError.server("Трека уже нет в плейлисте")
            }
            return [["op": "delete", "from": position, "to": position + 1, "tracks": [Self.reference(track)]]]
        }
    }

    /// Переставляет трек: он встаёт перед треком `before`, а без него — в конец.
    func moveInPlaylist(uid: String, kind: String, track: Track, before: String?) async throws {
        if TuneCatalogID.isSyntheticTrack(track.id) {
            CatalogLibraryStore.shared.movePlaylistTrack(track.id, owner: uid, kind: kind, before: before)
            return
        }
        try await change(uid: uid, kind: kind) { state in
            guard let from = Self.position(of: track.id, in: state) else {
                throw APIError.server("Трека уже нет в плейлисте")
            }
            var target = state["tracks"].array.count - 1
            if let before {
                if TuneCatalogID.isSyntheticTrack(before) {
                    target = 0
                } else if let next = Self.position(of: before, in: state) {
                    // После удаления трека всё, что стояло за ним, сдвигается на одну позицию.
                    target = next > from ? next - 1 : next
                }
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
    func history(limit: Int = 200, includeSources: Bool = true) async throws -> (tracks: [Track], days: [String: String], sources: [String: String]) {
        if Demo.on {
            let list = Array(Demo.data.tracks.reversed())
            var days: [String: String] = [:]
            if let first = list.first { days[first.id] = "Сегодня" }
            if list.count > 4 { days[list[4].id] = "Вчера" }
            return (list, days, list.first.map { [$0.id: "Моя волна"] } ?? [:])
        }
        let value = result(try await get("music-history", [("fullModelsCount", includeSources ? "\(limit)" : "0")]))
        var ids: [String] = []
        var dayOf: [String: String] = [:]
        var sources: [String: String] = [:]
        var seen = Set<String>()
        for tab in value["historyTabs"].array {
            let day = Self.dayName(tab["date"].string ?? "")
            for item in tab["items"].array {
                let source = Self.historySource(item["context"])
                for track in item["tracks"].array {
                    if let id = track["data"]["itemId"]["trackId"].idText, seen.insert(id).inserted {
                        ids.append(id)
                        dayOf[id] = day
                        sources[id] = source
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
        return (out, days, sources)
    }

    private static func historySource(_ context: JSON) -> String? {
        let model = context["data"]["fullModel"]
        switch context["type"].string {
        case "wave": return model["wave"]["title"].string ?? "Моя волна"
        case "playlist": return model["playlist"]["title"].string ?? "Плейлист"
        case "album": return model["album"]["title"].string ?? "Альбом"
        case "artist": return model["artist"]["name"].string ?? "Исполнитель"
        case "search": return "Поиск"
        default: return nil
        }
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
        if Demo.on {
            return HomePage(waves: Demo.data.waves, blocks: Demo.home, recent: Array(Demo.data.tracks.prefix(5)),
                            trends: Demo.home.filter { $0.id == "releases" || $0.id == "albums" })
        }
        let skeleton = result(try await get("landing/skeleton/main"))
        let tabs = skeleton["blocks"].array.map { $0["data"]["tabs"] }.first { $0.isArray } ?? JSON(nil)
        async let recent = try? history(limit: 8, includeSources: false)
        async let personal = homePage(blocks: tabs[0]["blocks"].array)
        async let trending = homePage(blocks: tabs[1]["blocks"].array)
        var page = await personal
        page.recent = (await recent)?.tracks
        let trends = await trending
        if !trends.blocks.isEmpty { page.trends = trends.blocks }
        return page
    }

    private func homePage(blocks: [JSON]) async -> HomePage {
        // Эти блоки ведут в разделы, которых в приложении нет.
        let skipped: Set<String> = ["LIKES_AND_HISTORY", "SPECIAL", "CONCERTS_PERSONAL", "DONATIONS"]
        var kinds: [String] = []
        var titles: [String] = []
        var paths: [String] = []
        for block in blocks {
            let kind = block["type"].string ?? ""
            guard !skipped.contains(kind), let uri = block["data"]["source"]["uri"].string,
                  !uri.hasPrefix("//"), !uri.contains("://") else { continue }
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

    func kids() async throws -> [HomeBlock] {
        if Demo.on {
            return [HomeBlock(id: "kids-playlists", title: "Детские плейлисты", items: Demo.data.playlists.prefix(4).map { .playlist($0) })]
        }
        let skeleton = result(try await get("landing/skeleton/kids"))
        let direct = skeleton["blocks"].array
        let tabs = direct.map { $0["data"]["tabs"] }.first { $0.isArray }
        let blocks = tabs.map { $0.array.flatMap { $0["blocks"].array } } ?? direct
        let page = await homePage(blocks: blocks)
        try Task.checkCancellation()
        var seen = Set<String>()
        return page.blocks.filter { block in
            // В разных вкладках Яндекс может вернуть одну и ту же полку.
            let identity = block.items.map(\.id).joined(separator: "|")
            return seen.insert(identity).inserted
        }
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
            let icon = station["icon"]["imageUrl"].string
            found[type, default: []].append(WaveCard(title: name, seeds: ["\(type):\(tag)"], cover: (icon?.isEmpty ?? true) ? nil : icon, color: station["icon"]["backgroundColor"].string))
        }
        return StationGroup.known.compactMap { group in
            guard let waves = found[group.id], !waves.isEmpty else { return nil }
            return StationGroup(id: group.id, title: group.title, waves: waves)
        }
    }

    /// «Не рекомендовать исполнителя»: его треки перестают попадаться в волнах.
    func setBlocked(uid: String, artist: String, blocked: Bool) async throws {
        if TuneCatalogID.isSyntheticArtist(artist) {
            CatalogLibraryStore.shared.setArtistDisliked(artist, blocked)
            return
        }
        let path = blocked ? "users/\(uid)/dislikes/artists/add?artist-id=\(artist)" : "users/\(uid)/dislikes/artists/\(artist)/remove"
        _ = try await post(path)
    }

    func waveNew(seeds: [String]) async throws -> Wave {
        let isSyntheticSeed: (String) -> Bool = { seed in
            if seed.hasPrefix("track:") { return TuneCatalogID.isSyntheticTrack(String(seed.dropFirst("track:".count))) }
            if seed.hasPrefix("artist:") { return TuneCatalogID.isSyntheticArtist(String(seed.dropFirst("artist:".count))) }
            return false
        }
        if !seeds.isEmpty && seeds.allSatisfy(isSyntheticSeed) {
            throw APIError.server("Волна недоступна для треков каталога Tune")
        }
        let value = result(try await post("rotor/session/new", json: ["seeds": seeds, "includeTracksInResponse": true, "allowExplicit": true]))
        guard let session = value["radioSessionId"].string else { throw APIError.server("Яндекс не запустил волну") }
        return Wave(session: session, tracks: Self.parseSequence(value))
    }

    /// Номера похожих исполнителей.
    func similarArtistIds(_ id: String) async throws -> [String] {
        if TuneCatalogID.isSyntheticArtist(id) { return [] }
        return result(try await get("artists/\(id)/similar"))["similarArtists"].array.compactMap { $0["id"].idText }
    }

    /// Какие из треков Яндекс закрыл. Смотрим на ответ как есть, до подмены «Без цензуры».
    func unavailableIds(_ ids: [String]) async throws -> [String] {
        let yandexIDs = ids.filter { !TuneCatalogID.isSyntheticTrack($0) }
        guard !yandexIDs.isEmpty else { return [] }
        let value = try await post("tracks", form: "track-ids=" + yandexIDs.joined(separator: "%2C"))
        return value["result"].array.filter { $0["available"].bool == false }.compactMap { $0["id"].idText }
    }

    /// Колесо волны: подсказки к тому, что играет. Ответ — номер колеса и подсказки.
    func wheel(seeds: [String], feedbacks: [[String: Any]]) async throws -> (String, [WheelItem]) {
        let value = result(try await post("wheel/new", json: ["context": ["type": "WAVE", "data": ["seeds": seeds]], "feedbacks": feedbacks]))
        guard let id = value["wheelId"].string else { throw APIError.server("Яндекс не прислал колесо волны") }
        return (id, value["items"].array.compactMap(Self.parseWheelItem))
    }

    func wheelFeedbacks(_ feedbacks: [[String: Any]]) async throws {
        _ = try await post("wheel/feedbacks", json: ["feedbacks": feedbacks])
    }

    /// Ссылки и «Моя волна на двоих» не поддерживаются: такие подсказки пропускаются.
    private static func parseWheelItem(_ value: JSON) -> WheelItem? {
        guard let kind = value["type"].string, let id = value["id"].idText else { return nil }
        let data = value["data"]
        switch kind {
        case "WAVE":
            let seeds = data["wave"]["seeds"].array.compactMap(\.string)
            guard !seeds.isEmpty, let title = data["wave"]["name"].string else { return nil }
            let cover = data["agent"]["cover"]
            return WheelItem(kind: kind, id: id, action: .wave(seeds), title: title, subtitle: data["wave"]["description"].string ?? "",
                             cover: cover["uri"].string, color: cover["color"].string)
        case "ALBUM":
            let album = data["album"]
            guard let albumId = album["id"].idText, let title = album["title"].string else { return nil }
            let artists = data["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
            return WheelItem(kind: kind, id: id, action: .album(albumId), title: title, subtitle: artists,
                             cover: album["cover"]["uri"].string ?? album["coverUri"].string, color: album["cover"]["color"].string)
        case "SETTING":
            guard let title = data["title"].string else { return nil }
            return WheelItem(kind: kind, id: id, action: .setting, title: title, subtitle: "", cover: data["cover"]["uri"].string, color: nil)
        default:
            return nil
        }
    }

    /// Карточки «Слов в волне» к трекам. Показанные с прошлого раза карточки и рассказы уходят
    /// вместе с запросом: Яндекс не повторяет их.
    func wordsCards(trackIds: [String], viewed: [String], viewedBig: [(String, [String])]) async throws -> [String: WordCard] {
        let big = viewedBig.map { ["cardId": $0.0, "bigCardIds": $0.1] as [String: Any] }
        let value = result(try await post("words/cards", json: ["trackIds": trackIds, "viewedCards": viewed, "viewedBigCards": big]))
        var out: [String: WordCard] = [:]
        for track in value.array {
            let item = track["cards"][0]
            let card = item["card"]
            guard let trackId = track["id"].idText, let id = card["id"].string,
                  let text = card["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            out[trackId] = WordCard(id: id, text: text, big: card["bigCardIds"][0].string, feedback: item["feedbackState"].string ?? "neutral")
        }
        return out
    }

    func wordsBig(big: String, track: String, card: String) async throws -> WordBig {
        let value = result(try await post("words/big-cards", json: ["bigCardIds": [big], "bigCardContexts": [["bigCardId": big, "trackId": track, "cardId": card]]]))[0]
        guard let text = value["text"].string?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw APIError.server("Яндекс не рассказал подробнее") }
        let action = value["actions"].array.first { ($0["url"].string ?? "").hasPrefix("https://") && $0["title"].string != nil }
        return WordBig(text: text, actionTitle: action?["title"].string, actionURL: action?["url"].string.flatMap(URL.init(string:)))
    }

    /// Оценка карточки: «Больше такого» — like, «Мимо» — dislike.
    func wordsFeedback(card: String, state: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["feedback": [["id": card, "feedbackState": state]]])
        _ = try await send("PUT", "words/cards/feedback", body: body, type: "application/json")
    }

    /// Следующая пачка волны; queue — уже показанные треки.
    func waveMore(session: String, queue: [String]) async throws -> [Track] {
        let value = result(try await post("rotor/session/\(session)/tracks", json: ["queue": queue, "allowExplicit": true]))
        return Self.parseSequence(value)
    }

    /// Что волна узнаёт о вкусе: запуск, начало, конец, пропуск.
    func waveFeedback(session: String, kind: String, track: Track?, played: Double?) async throws {
        if let track, TuneCatalogID.isSyntheticTrack(track.id) { return }
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
        let filtered = reports.filter { report in
            guard let trackID = report["trackId"] as? String else { return true }
            return !TuneCatalogID.isSyntheticTrack(trackID)
        }
        guard !filtered.isEmpty else { return }
        _ = try await post("plays", json: ["plays": filtered], query: [("clientNow", Self.now())])
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

    /// Текст трека: Яндекс, LRCLIB и NetEase — в порядке из настроек.
    func lyrics(for track: Track, forceRefresh: Bool = false) async throws -> LyricsText {
        let (text, complete) = try await resolveLyrics(for: track, forceRefresh: forceRefresh)
        if text.lines.isEmpty && !complete { throw TuneError("Не удалось загрузить текст") }
        return text
    }

    /// Заранее подгружает текст трека в кэш; возвращает `true`, если проверка завершилась
    /// окончательно (найден текст или все источники ответили).
    func prefetchLyrics(for track: Track) async -> Bool {
        ((try? await resolveLyrics(for: track, forceRefresh: false))?.1) ?? false
    }

    private func resolveLyrics(for track: Track, forceRefresh: Bool) async throws -> (LyricsText, Bool) {
        if Demo.on {
            return (LyricsText(lines: Demo.lyrics, authors: ["Автор текста", "Композитор"], source: "LRCLIB"), true)
        }
        // Однажды полученный текст лежит на устройстве: он есть и без сети.
        _ = Storage.lyrics
        if await Connectivity.shared.offline {
            if let saved = Self.cachedLyrics(for: track, anySource: true) { return (saved, true) }
            if let embedded = await Self.embeddedLyrics(for: track.id) { return (embedded, true) }
            return (LyricsText(lines: [], authors: nil, source: nil), false)
        }
        // Искали с теми же настройками — второй раз в сеть не идём.
        if !forceRefresh, let saved = Self.cachedLyrics(for: track, anySource: false) {
            return (saved, true)
        }
        let options = ExternalLyrics.Options.current
        let key = ExternalLyrics.settingsKey(for: options)
        let previous = Self.savedLyrics(for: track).flatMap { ExternalLyrics.enabledFallback($0, options: options) }
        let work: @Sendable () async throws -> (LyricsText, Bool) = {
            let name = "Lyrics/\(Storage.hash(track.id)).json"
            let ask: @Sendable (String) async throws -> LyricsText = { id in
                try await self.fetchLyrics(track: id)
            }
            let (found, complete) = await ExternalLyrics.find(track, options: options, yandex: ask, onFailure: { source, error in
                let code = error as NSError
                let details = (error as? ExternalLyrics.RequestFailure)?.errorDescription ?? "\(code.domain) (\(code.code))"
                Log.shared.add("текст: \(source): \(details)")
            })
            try Task.checkCancellation()
            // Аккаунту без Плюса Яндекс вместо текста отдаёт просьбу подключить подписку.
            // Её нельзя сохранять: иначе она останется и после входа в аккаунт с Плюсом.
            if !Self.isStub(found.lines), !found.lines.isEmpty {
                var result = found
                result.searched = complete ? key : "partial:\(key)"
                Storage.save(result, name)
                return (result, complete)
            }
            if let embedded = await Self.embeddedLyrics(for: track.id) {
                var result = embedded
                result.searched = complete ? key : "partial:\(key)"
                Storage.save(result, name)
                return (result, complete)
            }
            if let previous {
                return (previous, complete)
            }
            return (LyricsText(lines: [], authors: nil, source: nil), complete)
        }
        return try await lyricsInFlight.run(key: "\(track.id)|\(key)", operation: work)
    }

    /// Вместо текста пришла заглушка про подписку: пара строк со словом «подписка».
    private static func isStub(_ lines: [LyricLine]) -> Bool {
        ExternalLyrics.isStub(lines)
    }

    private func fetchLyrics(track id: String) async throws -> LyricsText {
        if TuneCatalogID.isSyntheticTrack(id) {
            return LyricsText(lines: [], authors: nil, source: nil)
        }
        var downloadError: Error?
        for format in ["LRC", "TEXT"] {
            let stamp = String(Int(Date().timeIntervalSince1970))
            let query = [("format", format), ("timeStamp", stamp), ("sign", signFull("\(id)\(stamp)"))]
            let value = result(try await send("GET", "tracks/\(Self.encode(id))/lyrics", query: query,
                                              timeout: 7, missingStatuses: [400, 403, 404]))
            guard let link = value["downloadUrl"].string, let url = URL(string: link), url.scheme == "https" else { continue }
            do {
                let (data, response) = try await http.data(for: URLRequest(url: url, timeoutInterval: 7))
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
                let lines = ExternalLyrics.filterYandex(Self.parseLRC(text))
                let authors = value["writers"].array.compactMap { $0.string }
                if lines.contains(where: { !$0.text.isEmpty }), !Self.isStub(lines) {
                    return LyricsText(lines: lines, authors: authors, source: LyricsText.yandex)
                }
            } catch {
                try Task.checkCancellation()
                downloadError = error
            }
        }
        if let downloadError { throw downloadError }
        return LyricsText(lines: [], authors: nil, source: nil)
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        ExternalLyrics.parseLRC(text)
    }
}

private actor LyricsInFlight {
    private var tasks: [String: Task<(LyricsText, Bool), Error>] = [:]

    func run(key: String, operation: @escaping @Sendable () async throws -> (LyricsText, Bool)) async throws -> (LyricsText, Bool) {
        if let existing = tasks[key] {
            return try await existing.value
        }
        let task = Task<(LyricsText, Bool), Error> {
            try await operation()
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
