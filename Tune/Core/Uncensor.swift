import Foundation

/// Без цензуры — по открытым данным FckCensor (github.com/Hazzz895/FckCensorData).
/// Для треков из списка вместо файла Яндекса играет версия без цензуры, у треков и альбомов
/// подменяются названия, исполнители и обложки, а удалённые Яндексом треки снова играют.
final class Uncensor {
    static let shared = Uncensor()

    private static let mirrors = [
        "https://raw.githubusercontent.com/Hazzz895/FckCensorData/refs/heads/main/",
        "https://cdn.jsdelivr.net/gh/Hazzz895/FckCensorData@main/",
    ]
    private static let ttl: TimeInterval = 3600
    private static let skip: Set<String> = ["__fckCensor", "audio", "insert", "noAuto", "volumes", "id"]

    private struct List {
        var files: [String: String] = [:]
        var tracks: [String: [String: Any]] = [:]
        var albums: [String: [String: Any]] = [:]
        var inserts: [String: (tracks: [String], albums: [String])] = [:]
        var trackAlbums: [String: [String: Any]] = [:]
        var byArtist: [String: (tracks: [String], albums: [String])] = [:]
    }

    private let lock = NSLock()
    private var list: List?
    private var mirror = UserDefaults.standard.integer(forKey: "uncensorMirror")
    private var loading = false
    private let cache = Storage.support.appendingPathComponent("uncensor.json")

    private var current: List? {
        guard Settings.uncensor else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    /// Читает сохранённый список и, если он старше часа, качает свежий.
    func start() {
        Task.detached(priority: .utility) { [self] in
            var age = TimeInterval.infinity
            if let data = try? Data(contentsOf: cache), let root = JSON.parse(data).dict {
                store(Self.parse(root))
                let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate]) as? Date
                age = modified.map { Date().timeIntervalSince($0) } ?? .infinity
            }
            if age > Self.ttl {
                await refresh()
            }
        }
    }

    func refresh() async {
        lock.lock()
        if loading {
            lock.unlock()
            return
        }
        loading = true
        let first = mirror
        lock.unlock()
        defer {
            lock.lock()
            loading = false
            lock.unlock()
        }
        var order = [first]
        for index in Self.mirrors.indices where index != first {
            order.append(index)
        }
        for index in order where Self.mirrors.indices.contains(index) {
            guard let url = URL(string: Self.mirrors[index] + "list_v2.json") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = JSON.parse(data).dict
            else { continue }
            try? data.write(to: cache, options: .atomic)
            lock.lock()
            mirror = index
            lock.unlock()
            UserDefaults.standard.set(index, forKey: "uncensorMirror")
            store(Self.parse(root))
            return
        }
    }

    private func store(_ new: List) {
        lock.lock()
        list = new
        lock.unlock()
    }

    /// Ссылки на версию трека без цензуры: сначала с зеркала, которое отдало список.
    func files(for id: String) -> [URL] {
        if let local = localAudio(id) { return [local] }
        if MetadataOverrides.shared.value(.track, id)?.usePlugin == false { return [] }
        guard let raw = current?.files[id] else { return [] }
        let full = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://" + raw
        lock.lock()
        let preferred = mirror
        lock.unlock()
        var out: [String] = []
        if full.hasPrefix(Self.mirrors[0]) {
            let rest = String(full.dropFirst(Self.mirrors[0].count))
            let ordered = preferred == 1 ? [Self.mirrors[1], Self.mirrors[0]] : [Self.mirrors[0], Self.mirrors[1]]
            out = ordered.map { $0 + rest }
        } else {
            out = [full]
        }
        return out.compactMap { URL(string: $0) }
    }

    /// Треки, у которых есть файл без цензуры.
    func fileIds() -> [String] {
        guard let files = current?.files else { return [] }
        return Array(files.keys)
    }

    func has(_ id: String) -> Bool {
        localAudio(id) != nil || (MetadataOverrides.shared.value(.track, id)?.usePlugin != false && current?.files[id] != nil)
    }

    func localAudio(_ id: String) -> URL? {
        guard let name = MetadataOverrides.shared.value(.track, id)?.audio,
              let url = MetadataOverrides.file(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Трек из ответа Яндекса с подменой; nil — подменять нечего.
    func patch(track: [String: Any], id: String) -> (fields: [String: Any], file: Bool)? {
        let user = MetadataOverrides.shared.value(.track, id)
        let list = user?.usePlugin == false ? nil : current
        let spoof = list?.tracks[id]
        let file = user?.audio != nil ? localAudio(id) != nil : list?.files[id] != nil
        if spoof == nil && !file && user == nil { return nil }
        var out = track
        if let spoof { Self.apply(&out, spoof) }
        if let user { Self.applyUser(user, to: &out) }
        if file {
            // Удалённый или закрытый в Яндексе трек с файлом снова играет.
            out["available"] = true
            out["error"] = nil
        }
        return (out, file)
    }

    func patch(album: [String: Any], id: String) -> [String: Any]? {
        let user = MetadataOverrides.shared.value(.album, id)
        let spoof = user?.usePlugin == false ? nil : current?.albums[id]
        guard spoof != nil || user != nil else { return nil }
        var out = album
        if let spoof { Self.apply(&out, spoof) }
        if let user { Self.applyUser(user, to: &out) }
        return out
    }

    func patch(artist: JSON) -> JSON {
        guard let id = artist["id"].idText, let user = MetadataOverrides.shared.value(.artist, id),
              var fields = artist.dict else { return artist }
        if !user.title.isEmpty { fields["name"] = user.title }
        if let cover = user.coverURI {
            fields["ogImage"] = cover
            fields["cover"] = ["uri": cover]
        }
        return JSON(fields)
    }

    private static func applyUser(_ user: MetadataOverride, to fields: inout [String: Any]) {
        if !user.title.isEmpty { fields["title"] = user.title }
        if let cover = user.coverURI { fields["coverUri"] = cover }
        let names = user.artists.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !names.isEmpty {
            let old = JSON(fields["artists"]).array
            fields["artists"] = names.enumerated().map { index, name -> [String: Any] in
                var artist: [String: Any] = ["name": name]
                if old.indices.contains(index), let id = old[index]["id"].idText { artist["id"] = id }
                return artist
            }
        }
    }

    func customDisks(album id: String) -> [[String]]? {
        guard let user = MetadataOverrides.shared.value(.album, id), !user.tracks.isEmpty else { return nil }
        let disks = user.tracks.components(separatedBy: "\n\n").map { MetadataOverride.ids($0, kind: "track") }
            .filter { !$0.isEmpty }
        return disks.isEmpty ? nil : disks
    }

    /// Треки альбома по дискам, как в списке: туда возвращаются удалённые Яндексом.
    func volumes(album id: String) -> [[String]]? {
        if let disks = customDisks(album: id) { return disks }
        if MetadataOverrides.shared.value(.album, id)?.usePlugin == false { return nil }
        guard let volumes = current?.albums[id]?["volumes"] as? [Any] else { return nil }
        let disks = volumes.compactMap { disk in (disk as? [Any])?.compactMap { Self.id(of: $0) } }
        return disks.contains { !$0.isEmpty } ? disks : nil
    }

    /// Треки и альбомы, добавленные в профиль исполнителя.
    func inserts(artist id: String) -> (tracks: [String], albums: [String]) {
        let user = MetadataOverrides.shared.value(.artist, id)
        let list = user?.usePlugin == false ? nil : current
        let extra = list?.inserts[id] ?? ([], [])
        let catalog = list?.byArtist[id] ?? ([], [])
        func unique(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        return (unique(MetadataOverride.ids(user?.tracks ?? "", kind: "track") + extra.tracks + catalog.tracks),
                unique(MetadataOverride.ids(user?.albums ?? "", kind: "album") + extra.albums + catalog.albums))
    }

    func search(_ query: String, tracks: Bool, albums: Bool) -> (tracks: [JSON], albums: [JSON]) {
        guard let list = current else { return ([], []) }
        func words(_ text: String) -> [String] {
            text.lowercased().replacingOccurrences(of: "ё", with: "е")
                .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let terms = words(query)
        guard !terms.isEmpty else { return ([], []) }

        func matches(_ entries: [JSON]) -> [JSON] {
            entries.compactMap { entry -> (JSON, Bool)? in
                guard let title = entry["title"].string, !title.isEmpty else { return nil }
                let names = entry["artists"].array + entry["albums"][0]["artists"].array
                let fields = [title, entry["version"].string, entry["albums"][0]["title"].string].compactMap { $0 }
                    + names.compactMap { $0["name"].string }
                let tokens = fields.flatMap(words)
                guard terms.allSatisfy({ term in tokens.contains { $0.hasPrefix(term) } }) else { return nil }
                return (entry, words(title) == terms)
            }.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return (lhs.0["title"].string ?? "", lhs.0["id"].idText ?? "")
                    < (rhs.0["title"].string ?? "", rhs.0["id"].idText ?? "")
            }.map { $0.0 }
        }

        return (
            tracks ? matches(list.tracks.keys.filter { list.files[$0] != nil }.map { Self.catalogTrack($0, in: list) }) : [],
            albums ? matches(list.albums.map { Self.catalogEntry($0.key, $0.value) }) : []
        )
    }

    func catalogTrack(_ id: String) -> JSON? {
        guard let list = current, has(id) else { return nil }
        let track = Self.catalogTrack(id, in: list)
        return track["title"].string?.isEmpty == false ? track : nil
    }

    func catalogAlbum(_ id: String) -> JSON? {
        guard let fields = current?.albums[id], let title = fields["title"] as? String, !title.isEmpty else { return nil }
        return Self.catalogEntry(id, fields)
    }

    private static func catalogEntry(_ id: String, _ metadata: [String: Any]) -> JSON {
        var fields: [String: Any] = ["id": id]
        apply(&fields, metadata)
        return JSON(fields)
    }

    private static func catalogTrack(_ id: String, in list: List) -> JSON {
        var fields = list.tracks[id] ?? [:]
        fields["available"] = false
        if let album = list.trackAlbums[id] {
            fields["albums"] = [album]
            if fields["artists"] == nil { fields["artists"] = album["artists"] }
        }
        return catalogEntry(id, fields)
    }

    private static func apply(_ target: inout [String: Any], _ spoof: [String: Any]) {
        for (key, value) in spoof {
            if skip.contains(key) || value is NSNull { continue }
            if key == "artists", (value as? [Any])?.isEmpty ?? true { continue }
            if key == "coverUri" {
                if var cover = target["cover"] as? [String: Any] {
                    cover["uri"] = value
                    cover["prefix"] = nil
                    target["cover"] = cover
                }
            }
            target[key] = value
        }
    }

    private static func isId(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private static func id(of value: Any) -> String? {
        var text: String?
        if let object = value as? [String: Any] {
            text = JSON(object["releaseId"]).idText ?? JSON(object["id"]).idText
        } else {
            text = JSON(value).idText
        }
        return text.flatMap { isId($0) ? $0 : nil }
    }

    /// Формат list_v2: в sources — подмены полей (tracks, albums) и хранилища файлов.
    /// Как у FckCensor: поля — из первого источника, где они есть, файлы — из последнего.
    private static func parse(_ root: [String: Any]) -> List {
        var list = List()
        for case let source as [String: Any] in (root["sources"] as? [Any]) ?? [] {
            for (id, value) in (source["tracks"] as? [String: Any]) ?? [:] {
                if isId(id), let fields = value as? [String: Any], list.tracks[id] == nil { list.tracks[id] = fields }
            }
            for (id, value) in (source["albums"] as? [String: Any]) ?? [:] {
                if isId(id), let fields = value as? [String: Any], list.albums[id] == nil { list.albums[id] = fields }
            }
            for (id, value) in (source["artistsInsertions"] as? [String: Any]) ?? [:] {
                guard isId(id), let fields = value as? [String: Any], list.inserts[id] == nil else { continue }
                let tracks = ((fields["tracks"] as? [Any]) ?? []).compactMap { Self.id(of: $0) }
                let albums = ((fields["albums"] as? [Any]) ?? []).compactMap { Self.id(of: $0) }
                list.inserts[id] = (tracks, albums)
            }
            for case let storage as [String: Any] in (source["tracksStorages"] as? [Any]) ?? [] {
                let template = storage["urlTemplate"] as? String ?? ""
                if !template.isEmpty {
                    for item in (storage["trackIds"] as? [Any]) ?? [] {
                        let object = item as? [String: Any]
                        guard let id = JSON(object?["id"] ?? item).idText, isId(id) else { continue }
                        list.files[id] = template.replacingOccurrences(of: "%%", with: id)
                        if let duration = object?["durationMs"] as? NSNumber {
                            list.tracks[id, default: [:]]["durationMs"] = duration
                        }
                    }
                }
                for (id, value) in (storage["tracks"] as? [String: Any]) ?? [:] {
                    guard isId(id) else { continue }
                    let object = value as? [String: Any]
                    let raw: Any? = object != nil ? object?["url"] : value
                    var url: String?
                    if let text = raw as? String {
                        url = (!text.contains("://") && !template.isEmpty) ? template.replacingOccurrences(of: "%%", with: text) : text
                    } else if let number = raw as? NSNumber, !template.isEmpty {
                        url = template.replacingOccurrences(of: "%%", with: number.stringValue)
                    }
                    if let url, !url.isEmpty { list.files[id] = url }
                    if let duration = object?["durationMs"] as? NSNumber {
                        list.tracks[id, default: [:]]["durationMs"] = duration
                    }
                }
            }
        }
        fillCupsizeMetadata(&list)
        // Треки подменённого альбома без своей обложки берут обложку альбома.
        for (albumID, album) in list.albums.sorted(by: { $0.key < $1.key }) {
            let fields = catalogEntry(albumID, album).dict
            for case let disk as [Any] in (album["volumes"] as? [Any]) ?? [] {
                for item in disk {
                    guard let id = Self.id(of: item) else { continue }
                    if list.trackAlbums[id] == nil { list.trackAlbums[id] = fields }
                    if list.tracks[id]?["coverUri"] == nil, let cover = album["coverUri"] as? String, !cover.isEmpty {
                        list.tracks[id, default: [:]]["coverUri"] = cover
                    }
                }
            }
        }
        func artists(_ fields: [String: Any]) -> [String] {
            JSON(fields)["artists"].array.compactMap { $0["id"].idText }
        }
        for (id, album) in list.albums.sorted(by: { $0.key < $1.key }) {
            for artist in artists(album) { list.byArtist[artist, default: ([], [])].albums.append(id) }
        }
        for id in list.files.keys.sorted() {
            let track = list.tracks[id] ?? [:]
            let owners = Set(artists(track) + (list.trackAlbums[id].map(artists) ?? []))
            for artist in owners { list.byArtist[artist, default: ([], [])].tracks.append(id) }
        }
        return list
    }

    /// У этого релиза FckCensor хранит порядок и аудио, а названия есть в ID3-тегах файлов.
    private static func fillCupsizeMetadata(_ list: inout List) {
        let albumID = "24720439"
        guard list.albums[albumID] != nil else { return }
        let artist: [String: Any] = ["id": 10946087, "name": "CUPSIZE"]
        let featured: [String: Any] = ["name": "17 SEVENTEEN"]
        let titles = [
            "110945082": "ДАВАЙ ТРАХАТЬСЯ В МАШИНЕ",
            "110945083": "люби меня, алина",
            "110945084": "ГИДРОПОН",
            "110945085": "Папик",
            "110945087": "вайфуу",
            "110945088": "я схавал опиат",
            "110945089": "Вирус",
            "110945090": "МОЯ МАМА ПЬЕТ",
            "110945091": "Ты любишь травку",
            "110945092": "Забуду",
            "110945093": "мне похуй",
        ]
        let album: [String: Any] = ["title": "Еби меня, малышка", "artists": [artist], "year": 2023]
        list.albums[albumID]?.merge(album) { existing, fallback in existing is NSNull ? fallback : existing }
        for (id, title) in titles where list.files[id] != nil {
            let artists = id == "110945085" ? [artist, featured] : [artist]
            let metadata: [String: Any] = ["title": title, "artists": artists, "contentWarning": "explicit"]
            list.tracks[id, default: [:]].merge(metadata) { existing, fallback in existing is NSNull ? fallback : existing }
        }
    }
}
