import Foundation

/// Разобранный список FckCensor или Каталога Tune (или их слияние).
struct CatalogList {
    var files: [String: String] = [:]
    var tracks: [String: [String: Any]] = [:]
    var albums: [String: [String: Any]] = [:]
    var artists: [String: [String: Any]] = [:]
    var playlists: [String: [String: Any]] = [:]
    var inserts: [String: (tracks: [String], albums: [String])] = [:]
    var trackAlbums: [String: [String: Any]] = [:]
    var byArtist: [String: (tracks: [String], albums: [String])] = [:]
}

enum CatalogIndex {
    private static let skip: Set<String> = ["__fckCensor", "audio", "insert", "noAuto", "volumes", "id"]

    static func isID(_ text: String) -> Bool {
        TuneCatalogID.isNumeric(text)
    }

    static func id(of value: Any) -> String? {
        let text: String?
        if let object = value as? [String: Any] {
            text = JSON(object["releaseId"]).idText ?? JSON(object["id"]).idText
        } else {
            text = JSON(value).idText
        }
        return text.flatMap { isID($0) ? $0 : nil }
    }

    static func idList(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { id(of: $0) }
    }

    static func parseSingle(_ root: [String: Any]) -> CatalogList {
        var list = CatalogList()
        parseMetadata(from: root, into: &list)
        parseStorages(from: root, into: &list)
        fillCupsizeMetadata(&list)
        finalize(&list)
        return list
    }

    /// Метаданные Каталога Tune имеют приоритет над FckCensorData;
    /// аудиопотоки — наоборот: Каталог Tune пишется вторым, перезаписывая FckCensorData.
    static func parseMerged(catalog catalogRoot: [String: Any], fck fckRoot: [String: Any]) -> CatalogList {
        var list = CatalogList()
        parseMetadata(from: catalogRoot, into: &list)
        parseMetadata(from: fckRoot, into: &list)
        parseStorages(from: fckRoot, into: &list)
        parseStorages(from: catalogRoot, into: &list)
        fillCupsizeMetadata(&list)
        finalize(&list)
        return list
    }

    static func parseMetadata(from root: [String: Any], into list: inout CatalogList) {
        for case let source as [String: Any] in (root["sources"] as? [Any]) ?? [] {
            for (id, value) in (source["tracks"] as? [String: Any]) ?? [:] {
                if isID(id), let fields = value as? [String: Any], list.tracks[id] == nil {
                    list.tracks[id] = fields
                }
            }
            for (id, value) in (source["albums"] as? [String: Any]) ?? [:] {
                if isID(id), let fields = value as? [String: Any], list.albums[id] == nil {
                    list.albums[id] = fields
                }
            }
            for (id, value) in (source["artists"] as? [String: Any]) ?? [:] {
                if isID(id), let fields = value as? [String: Any], list.artists[id] == nil {
                    list.artists[id] = fields
                }
            }
            for (id, value) in (source["playlists"] as? [String: Any]) ?? [:] {
                if isID(id), let fields = value as? [String: Any], list.playlists[id] == nil {
                    list.playlists[id] = fields
                }
            }
            for (id, value) in (source["artistsInsertions"] as? [String: Any]) ?? [:] {
                guard isID(id), let fields = value as? [String: Any] else { continue }
                var entry = list.inserts[id] ?? ([], [])
                for tid in idList(fields["tracks"]) where !entry.tracks.contains(tid) {
                    entry.tracks.append(tid)
                }
                for aid in idList(fields["albums"]) where !entry.albums.contains(aid) {
                    entry.albums.append(aid)
                }
                list.inserts[id] = entry
            }
        }
    }

    static func parseStorages(from root: [String: Any], into list: inout CatalogList) {
        for case let source as [String: Any] in (root["sources"] as? [Any]) ?? [] {
            for case let storage as [String: Any] in (source["tracksStorages"] as? [Any]) ?? [] {
                let template = storage["urlTemplate"] as? String ?? ""
                if !template.isEmpty {
                    for item in (storage["trackIds"] as? [Any]) ?? [] {
                        let object = item as? [String: Any]
                        guard let id = JSON(object?["id"] ?? item).idText, isID(id) else { continue }
                        list.files[id] = template.replacingOccurrences(of: "%%", with: id)
                        if let duration = object?["durationMs"] as? NSNumber {
                            list.tracks[id, default: [:]]["durationMs"] = duration
                        }
                    }
                }
                for (id, value) in (storage["tracks"] as? [String: Any]) ?? [:] {
                    guard isID(id) else { continue }
                    let object = value as? [String: Any]
                    let raw: Any? = object != nil ? object?["url"] : value
                    var url: String?
                    if let text = raw as? String {
                        url = (!text.contains("://") && !template.isEmpty) ? template.replacingOccurrences(of: "%%", with: text) : text
                    } else if let number = raw as? NSNumber, !template.isEmpty {
                        url = template.replacingOccurrences(of: "%%", with: number.stringValue)
                    }
                    if let url, !url.isEmpty {
                        list.files[id] = url
                    }
                    if let duration = object?["durationMs"] as? NSNumber {
                        list.tracks[id, default: [:]]["durationMs"] = duration
                    }
                }
            }
        }
    }

    static func finalize(_ list: inout CatalogList) {
        for (albumID, album) in list.albums.sorted(by: { $0.key < $1.key }) {
            let fields = catalogEntry(albumID, album).dict ?? [:]
            for case let disk as [Any] in (album["volumes"] as? [Any]) ?? [] {
                for item in disk {
                    guard let id = id(of: item) else { continue }
                    if list.trackAlbums[id] == nil {
                        list.trackAlbums[id] = fields
                    }
                    if list.tracks[id]?["coverUri"] == nil,
                       let cover = album["coverUri"] as? String, !cover.isEmpty {
                        list.tracks[id, default: [:]]["coverUri"] = cover
                    }
                }
            }
        }
        func artists(_ fields: [String: Any]) -> [String] {
            JSON(fields)["artists"].array.compactMap { $0["id"].idText }
        }
        for (id, album) in list.albums.sorted(by: { $0.key < $1.key }) {
            for artist in artists(album) {
                var entry = list.byArtist[artist] ?? ([], [])
                if !entry.albums.contains(id) { entry.albums.append(id) }
                list.byArtist[artist] = entry
            }
        }
        for id in list.files.keys.sorted() {
            let track = list.tracks[id] ?? [:]
            let owners = Set(artists(track) + (list.trackAlbums[id].map(artists) ?? []))
            for artist in owners.sorted() {
                var entry = list.byArtist[artist] ?? ([], [])
                if !entry.tracks.contains(id) { entry.tracks.append(id) }
                list.byArtist[artist] = entry
            }
        }
    }

    /// У этого релиза FckCensor хранит порядок и аудио, а названия есть в ID3-тегах файлов.
    private static func fillCupsizeMetadata(_ list: inout CatalogList) {
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

    static func apply(_ target: inout [String: Any], _ spoof: [String: Any]) {
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

    static func catalogEntry(_ id: String, _ metadata: [String: Any]) -> JSON {
        var fields: [String: Any] = ["id": id]
        apply(&fields, metadata)
        return JSON(fields)
    }

    static func catalogTrack(_ id: String, in list: CatalogList) -> JSON {
        var fields = list.tracks[id] ?? [:]
        fields["available"] = false
        if fields["albums"] == nil, let album = list.trackAlbums[id] {
            fields["albums"] = [album]
            if fields["artists"] == nil { fields["artists"] = album["artists"] }
        }
        return catalogEntry(id, fields)
    }

    static func searchWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func matchesQuery(_ query: String, fields: [String]) -> Bool {
        let terms = searchWords(query)
        guard !terms.isEmpty else { return false }
        let allowPrefix = terms.reduce(0) { $0 + $1.count } >= 2
        let tokens = fields.flatMap(searchWords)
        return terms.allSatisfy { term in
            allowPrefix ? tokens.contains { $0.hasPrefix(term) } : tokens.contains(term)
        }
    }
}

/// Чистое состояние объединённого и раздельных списков для тестов и `Uncensor`.
final class CatalogState {
    private let lock = NSLock()
    private var fckRaw: [String: Any]?
    private var catalogRaw: [String: Any]?
    private var fckList: CatalogList?
    private var catalogList: CatalogList?
    private var mergedList: CatalogList?
    private(set) var version: UInt64 = 0

    func setFck(_ root: [String: Any]?) {
        lock.lock()
        fckRaw = root
        rebuildLocked()
        lock.unlock()
    }

    func setCatalog(_ root: [String: Any]?) {
        lock.lock()
        catalogRaw = root
        rebuildLocked()
        lock.unlock()
    }

    func bumpVersion() {
        lock.lock()
        version &+= 1
        lock.unlock()
    }

    var hasFckData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fckList != nil
    }

    var hasCatalogData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return catalogList != nil
    }

    private func rebuildLocked() {
        fckList = fckRaw.map(CatalogIndex.parseSingle)
        catalogList = catalogRaw.map(CatalogIndex.parseSingle)
        switch (catalogRaw, fckRaw) {
        case (let cat?, let fck?):
            mergedList = CatalogIndex.parseMerged(catalog: cat, fck: fck)
        case (let cat?, nil):
            mergedList = CatalogIndex.parseSingle(cat)
        case (nil, let fck?):
            mergedList = CatalogIndex.parseSingle(fck)
        case (nil, nil):
            mergedList = nil
        }
        version &+= 1
    }

    func current(uncensorEnabled: Bool, catalogEnabled: Bool) -> CatalogList? {
        lock.lock()
        defer { lock.unlock() }
        switch (uncensorEnabled, catalogEnabled) {
        case (true, true): return mergedList
        case (true, false): return fckList
        case (false, true): return catalogList
        case (false, false): return nil
        }
    }

    func catalogOnly(catalogEnabled: Bool) -> CatalogList? {
        guard catalogEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return catalogList
    }

    func fckOnly(uncensorEnabled: Bool) -> CatalogList? {
        guard uncensorEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fckList
    }

    /// Значок «T» — только когда Каталог Tune включён и у трека есть файл именно в каталоге Tune.
    func isCatalogTrack(_ id: String, catalogEnabled: Bool, autoOn: Bool = true) -> Bool {
        guard catalogEnabled, autoOn else { return false }
        lock.lock()
        let found = catalogList?.files[id] != nil
        lock.unlock()
        return found
    }

    /// Значок замка FckCensor — только для треков с файлом в FckCensor и без значка «T».
    func hasFckCensor(_ id: String, uncensorEnabled: Bool, catalogEnabled: Bool, autoOn: Bool = true) -> Bool {
        guard uncensorEnabled, autoOn, !isCatalogTrack(id, catalogEnabled: catalogEnabled, autoOn: autoOn) else { return false }
        lock.lock()
        let found = fckList?.files[id] != nil
        lock.unlock()
        return found
    }

    func hasAudio(_ id: String, uncensorEnabled: Bool, catalogEnabled: Bool, autoOn: Bool = true) -> Bool {
        guard autoOn, let list = current(uncensorEnabled: uncensorEnabled, catalogEnabled: catalogEnabled) else { return false }
        return list.files[id] != nil
    }

    func catalogTrack(_ id: String, uncensorEnabled: Bool, catalogEnabled: Bool, allowWithoutFile: Bool = false) -> JSON? {
        guard let list = current(uncensorEnabled: uncensorEnabled, catalogEnabled: catalogEnabled) else { return nil }
        guard allowWithoutFile || list.files[id] != nil else { return nil }
        let track = CatalogIndex.catalogTrack(id, in: list)
        return track["title"].string?.isEmpty == false ? track : nil
    }

    func catalogAlbum(_ id: String, uncensorEnabled: Bool, catalogEnabled: Bool) -> JSON? {
        guard let list = current(uncensorEnabled: uncensorEnabled, catalogEnabled: catalogEnabled),
              let fields = list.albums[id],
              let title = fields["title"] as? String, !title.isEmpty else { return nil }
        return CatalogIndex.catalogEntry(id, fields)
    }

    func volumes(album id: String, uncensorEnabled: Bool, catalogEnabled: Bool) -> [[String]]? {
        guard let list = current(uncensorEnabled: uncensorEnabled, catalogEnabled: catalogEnabled),
              let volumes = list.albums[id]?["volumes"] as? [Any] else { return nil }
        let disks = volumes.compactMap { disk in (disk as? [Any])?.compactMap { CatalogIndex.id(of: $0) } }
        return disks.contains { !$0.isEmpty } ? disks : nil
    }

    func catalogArtist(_ id: String, uncensorEnabled: Bool, catalogEnabled: Bool) -> (json: JSON, trackIDs: [String], albumIDs: [String])? {
        guard let list = current(uncensorEnabled: uncensorEnabled, catalogEnabled: catalogEnabled) ?? catalogOnly(catalogEnabled: catalogEnabled),
              let fields = list.artists[id] else { return nil }
        var obj = fields
        obj["id"] = id
        var seenTracks = Set<String>()
        var trackIDs: [String] = []
        var seenAlbums = Set<String>()
        var albumIDs: [String] = []

        if let ins = list.inserts[id] {
            for tid in ins.tracks where seenTracks.insert(tid).inserted { trackIDs.append(tid) }
            for aid in ins.albums where seenAlbums.insert(aid).inserted { albumIDs.append(aid) }
        }

        func hasArtist(_ obj: [String: Any]) -> Bool {
            JSON(obj)["artists"].array.contains { CatalogIndex.id(of: $0.raw ?? [:]) == id }
        }

        for tid in list.tracks.keys.sorted() {
            if let fields = list.tracks[tid], hasArtist(fields),
               (list.files[tid] != nil || !TuneCatalogID.isSyntheticTrack(tid)),
               seenTracks.insert(tid).inserted {
                trackIDs.append(tid)
            }
        }
        for aid in list.albums.keys.sorted() {
            if let fields = list.albums[aid], hasArtist(fields), seenAlbums.insert(aid).inserted {
                albumIDs.append(aid)
            }
        }
        return (JSON(obj), trackIDs, albumIDs)
    }

    func catalogPlaylist(_ kind: String, catalogEnabled: Bool) -> (fields: [String: Any], trackIDs: [String])? {
        guard let list = catalogOnly(catalogEnabled: catalogEnabled),
              let fields = list.playlists[kind] else { return nil }
        return (fields, CatalogIndex.idList(fields["tracks"]))
    }

    func search(
        _ query: String,
        tracks wantTracks: Bool,
        albums wantAlbums: Bool,
        artists wantArtists: Bool = false,
        playlists wantPlaylists: Bool = false,
        uncensorEnabled: Bool,
        catalogEnabled: Bool
    ) -> (tracks: [JSON], albums: [JSON], artists: [JSON], playlists: [(kind: String, fields: [String: Any])]) {
        guard let list = current(uncensorEnabled: uncensorEnabled, catalogEnabled: catalogEnabled) else {
            return ([], [], [], [])
        }
        let terms = CatalogIndex.searchWords(query)
        guard !terms.isEmpty else { return ([], [], [], []) }

        func matchTitleObjects(_ entries: [JSON], titleKey: String = "title") -> [JSON] {
            entries.compactMap { entry -> (JSON, Bool)? in
                guard let title = entry[titleKey].string, !title.isEmpty else { return nil }
                let names = entry["artists"].array + entry["albums"][0]["artists"].array
                let fields = [title, entry["version"].string, entry["albums"][0]["title"].string].compactMap { $0 }
                    + names.compactMap { $0["name"].string }
                guard CatalogIndex.matchesQuery(query, fields: fields) else { return nil }
                return (entry, CatalogIndex.searchWords(title) == terms)
            }.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 }
                return (lhs.0[titleKey].string ?? "", lhs.0["id"].idText ?? "")
                    < (rhs.0[titleKey].string ?? "", rhs.0["id"].idText ?? "")
            }.map(\.0)
        }

        let foundTracks = wantTracks
            ? matchTitleObjects(list.tracks.keys.filter { list.files[$0] != nil }.map { CatalogIndex.catalogTrack($0, in: list) })
            : []
        let foundAlbums = wantAlbums
            ? matchTitleObjects(list.albums.map { CatalogIndex.catalogEntry($0.key, $0.value) })
            : []
        let catList = catalogOnly(catalogEnabled: catalogEnabled)
        let foundArtists: [JSON] = wantArtists && catList != nil
            ? matchTitleObjects(catList!.artists.map { CatalogIndex.catalogEntry($0.key, $0.value) }, titleKey: "name")
            : []
        let foundPlaylists: [(kind: String, fields: [String: Any])] = wantPlaylists && catList != nil
            ? catList!.playlists.compactMap { kind, fields -> (kind: String, fields: [String: Any], exact: Bool)? in
                guard let title = fields["title"] as? String, !title.isEmpty else { return nil }
                let desc = fields["description"] as? String ?? ""
                guard CatalogIndex.matchesQuery(query, fields: [title, desc]) else { return nil }
                return (kind, fields, CatalogIndex.searchWords(title) == terms)
            }.sorted { lhs, rhs in
                if lhs.exact != rhs.exact { return lhs.exact }
                return ((lhs.fields["title"] as? String) ?? "", lhs.kind)
                    < ((rhs.fields["title"] as? String) ?? "", rhs.kind)
            }.map { ($0.kind, $0.fields) }
            : []

        return (foundTracks, foundAlbums, foundArtists, foundPlaylists)
    }
}

/// Состояние элемента с LWW-меткой времени (epoch секунд) для `tune-sync:v1`.
struct SyncItemState: Codable, Equatable {
    var active: Bool
    var ts: Int64
}

/// Локальная медиатека для синтетических треков, альбомов, исполнителей и плейлистов Каталога Tune.
struct CatalogLibrary: Codable, Equatable {
    var likedTracks: [String] = []
    var dislikedTracks: [String] = []
    var likedAlbums: [String] = []
    var likedArtists: [String] = []
    var dislikedArtists: [String] = []
    var likedPlaylists: [String] = []
    var playlistTracks: [String: [String]] = [:]
    var pins: [String] = []

    var likedTracksMeta: [String: SyncItemState] = [:]
    var dislikedTracksMeta: [String: SyncItemState] = [:]
    var likedAlbumsMeta: [String: SyncItemState] = [:]
    var likedArtistsMeta: [String: SyncItemState] = [:]
    var dislikedArtistsMeta: [String: SyncItemState] = [:]
    var likedPlaylistsMeta: [String: SyncItemState] = [:]
    var playlistMeta: [String: Int64] = [:]
    var pinsMeta: [String: SyncItemState] = [:]

    enum CodingKeys: String, CodingKey {
        case likedTracks, dislikedTracks, likedAlbums, likedArtists, dislikedArtists, likedPlaylists
        case playlistTracks, pins
        case likedTracksMeta, dislikedTracksMeta, likedAlbumsMeta, likedArtistsMeta, dislikedArtistsMeta, likedPlaylistsMeta
        case playlistMeta, pinsMeta
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likedTracks = try c.decodeIfPresent([String].self, forKey: .likedTracks) ?? []
        dislikedTracks = try c.decodeIfPresent([String].self, forKey: .dislikedTracks) ?? []
        likedAlbums = try c.decodeIfPresent([String].self, forKey: .likedAlbums) ?? []
        likedArtists = try c.decodeIfPresent([String].self, forKey: .likedArtists) ?? []
        dislikedArtists = try c.decodeIfPresent([String].self, forKey: .dislikedArtists) ?? []
        likedPlaylists = try c.decodeIfPresent([String].self, forKey: .likedPlaylists) ?? []
        playlistTracks = try c.decodeIfPresent([String: [String]].self, forKey: .playlistTracks) ?? [:]
        pins = try c.decodeIfPresent([String].self, forKey: .pins) ?? []
        likedTracksMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .likedTracksMeta) ?? [:]
        dislikedTracksMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .dislikedTracksMeta) ?? [:]
        likedAlbumsMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .likedAlbumsMeta) ?? [:]
        likedArtistsMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .likedArtistsMeta) ?? [:]
        dislikedArtistsMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .dislikedArtistsMeta) ?? [:]
        likedPlaylistsMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .likedPlaylistsMeta) ?? [:]
        playlistMeta = try c.decodeIfPresent([String: Int64].self, forKey: .playlistMeta) ?? [:]
        pinsMeta = try c.decodeIfPresent([String: SyncItemState].self, forKey: .pinsMeta) ?? [:]
    }

    var hasActiveData: Bool {
        !likedTracks.isEmpty || !dislikedTracks.isEmpty || !likedAlbums.isEmpty
            || !likedArtists.isEmpty || !dislikedArtists.isEmpty || !likedPlaylists.isEmpty
            || playlistTracks.values.contains { !$0.isEmpty } || !pins.isEmpty
    }

    private static func pushFront(_ list: inout [String], _ id: String) {
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
    }

    mutating func setTrackLiked(_ id: String, _ liked: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if liked {
            if dislikedTracks.contains(id) || dislikedTracksMeta[id]?.active == true {
                dislikedTracks.removeAll { $0 == id }
                dislikedTracksMeta[id] = SyncItemState(active: false, ts: ts)
            }
            Self.pushFront(&likedTracks, id)
        } else {
            likedTracks.removeAll { $0 == id }
        }
        likedTracksMeta[id] = SyncItemState(active: liked, ts: ts)
    }

    mutating func setTrackDisliked(_ id: String, _ disliked: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if disliked {
            if likedTracks.contains(id) || likedTracksMeta[id]?.active == true {
                likedTracks.removeAll { $0 == id }
                likedTracksMeta[id] = SyncItemState(active: false, ts: ts)
            }
            Self.pushFront(&dislikedTracks, id)
        } else {
            dislikedTracks.removeAll { $0 == id }
        }
        dislikedTracksMeta[id] = SyncItemState(active: disliked, ts: ts)
    }

    mutating func setAlbumLiked(_ id: String, _ liked: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if liked {
            Self.pushFront(&likedAlbums, id)
        } else {
            likedAlbums.removeAll { $0 == id }
        }
        likedAlbumsMeta[id] = SyncItemState(active: liked, ts: ts)
    }

    mutating func setArtistLiked(_ id: String, _ liked: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if liked {
            if dislikedArtists.contains(id) || dislikedArtistsMeta[id]?.active == true {
                dislikedArtists.removeAll { $0 == id }
                dislikedArtistsMeta[id] = SyncItemState(active: false, ts: ts)
            }
            Self.pushFront(&likedArtists, id)
        } else {
            likedArtists.removeAll { $0 == id }
        }
        likedArtistsMeta[id] = SyncItemState(active: liked, ts: ts)
    }

    mutating func setArtistDisliked(_ id: String, _ disliked: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if disliked {
            if likedArtists.contains(id) || likedArtistsMeta[id]?.active == true {
                likedArtists.removeAll { $0 == id }
                likedArtistsMeta[id] = SyncItemState(active: false, ts: ts)
            }
            Self.pushFront(&dislikedArtists, id)
        } else {
            dislikedArtists.removeAll { $0 == id }
        }
        dislikedArtistsMeta[id] = SyncItemState(active: disliked, ts: ts)
    }

    mutating func setPlaylistLiked(_ kind: String, _ liked: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if liked {
            Self.pushFront(&likedPlaylists, kind)
        } else {
            likedPlaylists.removeAll { $0 == kind }
        }
        likedPlaylistsMeta[kind] = SyncItemState(active: liked, ts: ts)
    }

    /// Возвращает число реально добавленных новых треков (без дубликатов).
    @discardableResult
    mutating func addPlaylistTracks(_ ids: [String], to key: String, atEnd: Bool = false, now: Int64? = nil) -> Int {
        var list = playlistTracks[key] ?? []
        let oldList = list
        let before = Set(list)
        if atEnd {
            for id in ids where !list.contains(id) {
                list.append(id)
            }
        } else {
            for id in ids.reversed() {
                Self.pushFront(&list, id)
            }
        }
        playlistTracks[key] = list
        if list != oldList || playlistMeta[key] == nil {
            playlistMeta[key] = now ?? TuneSyncCodec.nowSeconds()
        }
        return Set(list).subtracting(before).count
    }

    mutating func removePlaylistTrack(_ trackID: String, from key: String, now: Int64? = nil) -> Bool {
        guard var list = playlistTracks[key] else { return false }
        let before = list.count
        list.removeAll { $0 == trackID }
        if list.isEmpty {
            playlistTracks.removeValue(forKey: key)
        } else {
            playlistTracks[key] = list
        }
        if list.count != before {
            playlistMeta[key] = now ?? TuneSyncCodec.nowSeconds()
        }
        return list.count != before
    }

    mutating func movePlaylistTrack(_ trackID: String, in key: String, before nextID: String?, now: Int64? = nil) {
        guard var list = playlistTracks[key], let from = list.firstIndex(of: trackID) else { return }
        let oldList = list
        list.remove(at: from)
        if let nextID, let target = list.firstIndex(of: nextID) {
            list.insert(trackID, at: target)
        } else {
            list.append(trackID)
        }
        playlistTracks[key] = list
        if list != oldList {
            playlistMeta[key] = now ?? TuneSyncCodec.nowSeconds()
        }
    }

    mutating func clearPlaylist(_ key: String, now: Int64? = nil) {
        let had = playlistTracks.removeValue(forKey: key) != nil || playlistMeta[key] != nil
        if had {
            playlistMeta[key] = now ?? TuneSyncCodec.nowSeconds()
        }
    }

    mutating func setPin(_ key: String, pinned: Bool, now: Int64? = nil) {
        let ts = now ?? TuneSyncCodec.nowSeconds()
        if pinned {
            Self.pushFront(&pins, key)
        } else {
            pins.removeAll { $0 == key }
        }
        pinsMeta[key] = SyncItemState(active: pinned, ts: ts)
    }

    /// Заполняет недостающие LWW-метки для устаревших записей без меток времени.
    @discardableResult
    mutating func ensureMigrated(now: Int64 = TuneSyncCodec.nowSeconds()) -> Bool {
        var changed = false
        func seed(_ list: [String], into meta: inout [String: SyncItemState]) {
            for (index, id) in list.enumerated() where meta[id] == nil || meta[id]?.active == false {
                meta[id] = SyncItemState(active: true, ts: now - Int64(index))
                changed = true
            }
        }
        seed(likedTracks, into: &likedTracksMeta)
        seed(dislikedTracks, into: &dislikedTracksMeta)
        seed(likedAlbums, into: &likedAlbumsMeta)
        seed(likedArtists, into: &likedArtistsMeta)
        seed(dislikedArtists, into: &dislikedArtistsMeta)
        seed(likedPlaylists, into: &likedPlaylistsMeta)
        seed(pins, into: &pinsMeta)
        for (offset, key) in playlistTracks.keys.sorted().enumerated() where playlistMeta[key] == nil {
            playlistMeta[key] = now - Int64(offset)
            changed = true
        }
        return changed
    }

    mutating func rebuildActiveArrays() {
        func activeList(_ meta: [String: SyncItemState]) -> [String] {
            meta.filter(\.value.active)
                .sorted { lhs, rhs in
                    if lhs.value.ts != rhs.value.ts { return lhs.value.ts > rhs.value.ts }
                    return lhs.key < rhs.key
                }
                .map(\.key)
        }
        likedTracks = activeList(likedTracksMeta)
        dislikedTracks = activeList(dislikedTracksMeta)
        likedAlbums = activeList(likedAlbumsMeta)
        likedArtists = activeList(likedArtistsMeta)
        dislikedArtists = activeList(dislikedArtistsMeta)
        likedPlaylists = activeList(likedPlaylistsMeta)
        pins = activeList(pinsMeta)
        playlistTracks = playlistTracks.filter { !$0.value.isEmpty }
    }

    static func merge(
        local: CatalogLibrary,
        remote: CatalogLibrary,
        now: Int64 = TuneSyncCodec.nowSeconds()
    ) -> (merged: CatalogLibrary, changedLocal: Bool, localDiffersFromRemote: Bool) {
        var lhs = local
        var rhs = remote
        _ = lhs.ensureMigrated(now: now)
        _ = rhs.ensureMigrated(now: now)

        func mergeMeta(_ a: [String: SyncItemState], _ b: [String: SyncItemState]) -> [String: SyncItemState] {
            var out = a
            for (key, rb) in b {
                if let la = out[key] {
                    if rb.ts > la.ts {
                        out[key] = rb
                    } else if rb.ts == la.ts && rb.active && !la.active {
                        out[key] = rb
                    }
                } else {
                    out[key] = rb
                }
            }
            return out
        }

        func reconcile(_ likes: inout [String: SyncItemState], _ dislikes: inout [String: SyncItemState]) {
            let shared = Set(likes.keys).intersection(dislikes.keys)
            for id in shared {
                guard let l = likes[id], let d = dislikes[id], l.active && d.active else { continue }
                if d.ts > l.ts {
                    likes[id] = SyncItemState(active: false, ts: d.ts)
                } else {
                    dislikes[id] = SyncItemState(active: false, ts: l.ts)
                }
            }
        }

        var merged = CatalogLibrary()
        merged.likedTracksMeta = mergeMeta(lhs.likedTracksMeta, rhs.likedTracksMeta)
        merged.dislikedTracksMeta = mergeMeta(lhs.dislikedTracksMeta, rhs.dislikedTracksMeta)
        reconcile(&merged.likedTracksMeta, &merged.dislikedTracksMeta)
        merged.likedAlbumsMeta = mergeMeta(lhs.likedAlbumsMeta, rhs.likedAlbumsMeta)
        merged.likedArtistsMeta = mergeMeta(lhs.likedArtistsMeta, rhs.likedArtistsMeta)
        merged.dislikedArtistsMeta = mergeMeta(lhs.dislikedArtistsMeta, rhs.dislikedArtistsMeta)
        reconcile(&merged.likedArtistsMeta, &merged.dislikedArtistsMeta)
        merged.likedPlaylistsMeta = mergeMeta(lhs.likedPlaylistsMeta, rhs.likedPlaylistsMeta)
        merged.pinsMeta = mergeMeta(lhs.pinsMeta, rhs.pinsMeta)

        let allPlaylistKeys = Set(lhs.playlistMeta.keys)
            .union(rhs.playlistMeta.keys)
            .union(lhs.playlistTracks.keys)
            .union(rhs.playlistTracks.keys)
        for key in allPlaylistKeys {
            let lts = lhs.playlistMeta[key]
            let rts = rhs.playlistMeta[key]
            let lTracks = lhs.playlistTracks[key] ?? []
            let rTracks = rhs.playlistTracks[key] ?? []
            let takeRemote: Bool
            switch (lts, rts) {
            case (nil, .some):
                takeRemote = true
            case (.some, nil):
                takeRemote = false
            case (let l?, let r?):
                if r > l {
                    takeRemote = true
                } else if r < l {
                    takeRemote = false
                } else if lTracks == rTracks {
                    takeRemote = false
                } else if rTracks.isEmpty != lTracks.isEmpty {
                    takeRemote = !rTracks.isEmpty
                } else if rTracks.count != lTracks.count {
                    takeRemote = rTracks.count > lTracks.count
                } else {
                    takeRemote = rTracks.joined(separator: ".") > lTracks.joined(separator: ".")
                }
            case (nil, nil):
                takeRemote = rTracks.count > lTracks.count
            }
            if takeRemote {
                if !rTracks.isEmpty { merged.playlistTracks[key] = rTracks }
                if let rts { merged.playlistMeta[key] = rts }
            } else {
                if !lTracks.isEmpty { merged.playlistTracks[key] = lTracks }
                if let lts { merged.playlistMeta[key] = lts }
            }
        }

        merged.rebuildActiveArrays()
        let changedLocal = merged != local
        let differsFromRemote = merged != rhs
        return (merged, changedLocal, differsFromRemote)
    }
}

/// Протокол синхронизации медиатеки Каталога Tune (`tune-sync:v1`).
enum TuneSyncCodec {
    static let maxDescriptionLength = 490
    static let tsEpoch: Int64 = 1_700_000_000
    static let tombstoneTTL: Int64 = 2_592_000
    static let shardZeroHeader = "Служебный плейлист Tune — синхронизация лайков и медиатеки Каталога Tune между устройствами. Не удаляйте его (в Tune он скрыт)."

    enum RemoteParseResult: Equatable {
        case empty
        case incomplete(String)
        case ready(libraries: [CatalogLibrary], duplicatesDetected: Bool, needsCleanup: Bool)
    }

    static func nowSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    static func shardHeader(index: Int) -> String {
        if index == 0 { return shardZeroHeader }
        return "Служебный плейлист Tune (часть \(index + 1)) — синхронизация Каталога Tune. Не удаляйте."
    }

    static func playlistTitle(index: Int) -> String {
        index == 0 ? "Tune Sync" : "Tune Sync \(index + 1)"
    }

    static func isSyncPlaylist(title: String, description: String?) -> Bool {
        if let description, description.contains("[tune-sync:v1:") { return true }
        if title == "Tune Sync" { return true }
        return title.range(of: "^Tune Sync [2-9]\\d*$", options: .regularExpression) != nil
    }

    static func shardIndexFromTitle(_ title: String) -> Int? {
        if title == "Tune Sync" { return 0 }
        guard title.range(of: "^Tune Sync [2-9]\\d*$", options: .regularExpression) != nil,
              let part = Int(title.dropFirst("Tune Sync ".count)), part >= 2 else { return nil }
        return part - 1
    }

    static func encodeId(_ raw: String, base: Int64) -> String {
        guard !raw.isEmpty else { return "" }
        if TuneCatalogID.isNumeric(raw), let n = Int64(raw),
           n > base && n <= base + 999_999_999 {
            return String(n - base, radix: 36, uppercase: false)
        }
        return "~\(raw)"
    }

    static func decodeId(_ token: String, base: Int64) -> String? {
        guard !token.isEmpty else { return nil }
        if token.hasPrefix("~") {
            let raw = String(token.dropFirst())
            return raw.isEmpty ? nil : raw
        }
        guard let delta = Int64(token, radix: 36), delta > 0 && delta <= 999_999_999 else {
            return nil
        }
        return String(base + delta)
    }

    static func encodeTs(_ epochSec: Int64) -> String {
        String(max(0, epochSec - tsEpoch), radix: 36, uppercase: false)
    }

    static func decodeTs(_ token: String) -> Int64? {
        guard !token.isEmpty, let delta = Int64(token, radix: 36), delta >= 0 else { return nil }
        return tsEpoch + delta
    }

    private static func pinBase(for kind: String) -> Int64? {
        switch kind {
        case "album": return TuneCatalogID.syntheticAlbumBase
        case "artist": return TuneCatalogID.syntheticArtistBase
        case "playlist": return TuneCatalogID.syntheticPlaylistBase
        case "track": return TuneCatalogID.syntheticTrackBase
        default: return nil
        }
    }

    private static func isAllowedPayload(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
                || v == 95 || v == 43 || v == 64 || v == 46 || v == 44 || v == 61 || v == 58 || v == 59 || v == 126 || v == 45
        }
    }

    static func encode(_ library: CatalogLibrary, uid: String? = nil, now: Int64 = nowSeconds()) -> String {
        var lib = library
        _ = lib.ensureMigrated(now: now)

        var sections: [String] = []

        func encodeSet(_ code: String, _ meta: [String: SyncItemState], base: Int64) {
            let items = meta.filter { _, state in
                state.active || (now - state.ts) <= tombstoneTTL
            }.sorted { lhs, rhs in
                if lhs.value.ts != rhs.value.ts { return lhs.value.ts > rhs.value.ts }
                if lhs.value.active != rhs.value.active { return lhs.value.active }
                return lhs.key < rhs.key
            }.compactMap { id, state -> String? in
                let enc = encodeId(id, base: base)
                guard !enc.isEmpty else { return nil }
                return "\(state.active ? "+" : "-")\(enc)@\(encodeTs(state.ts))"
            }
            if !items.isEmpty {
                sections.append("\(code):\(items.joined(separator: ","))")
            }
        }

        encodeSet("L", lib.likedTracksMeta, base: TuneCatalogID.syntheticTrackBase)
        encodeSet("D", lib.dislikedTracksMeta, base: TuneCatalogID.syntheticTrackBase)
        encodeSet("A", lib.likedAlbumsMeta, base: TuneCatalogID.syntheticAlbumBase)
        encodeSet("R", lib.likedArtistsMeta, base: TuneCatalogID.syntheticArtistBase)
        encodeSet("B", lib.dislikedArtistsMeta, base: TuneCatalogID.syntheticArtistBase)
        encodeSet("Q", lib.likedPlaylistsMeta, base: TuneCatalogID.syntheticPlaylistBase)

        let allPlKeys = Set(lib.playlistTracks.keys).union(lib.playlistMeta.keys)
        var plEntries: [(kind: String, line: String)] = []
        for key in allPlKeys {
            let wireKind: String
            if let uid, !uid.isEmpty {
                if key.hasPrefix("\(uid):") {
                    wireKind = String(key.dropFirst(uid.count + 1))
                } else if key.contains(":") {
                    continue
                } else {
                    wireKind = key
                }
            } else {
                wireKind = key
            }
            guard !wireKind.isEmpty else { continue }
            let tracks = lib.playlistTracks[key] ?? []
            let ts = lib.playlistMeta[key] ?? now
            if tracks.isEmpty && (lib.playlistMeta[key] == nil || (now - ts) > tombstoneTTL) {
                continue
            }
            let encTracks = tracks.map { encodeId($0, base: TuneCatalogID.syntheticTrackBase) }.filter { !$0.isEmpty }
            plEntries.append((wireKind, "\(wireKind)@\(encodeTs(ts))=\(encTracks.joined(separator: "."))"))
        }
        if !plEntries.isEmpty {
            plEntries.sort { $0.kind < $1.kind }
            sections.append("P:\(plEntries.map(\.line).joined(separator: ","))")
        }

        let pinEntries = lib.pinsMeta.filter { _, state in
            state.active || (now - state.ts) <= tombstoneTTL
        }.sorted { lhs, rhs in
            if lhs.value.ts != rhs.value.ts { return lhs.value.ts > rhs.value.ts }
            if lhs.value.active != rhs.value.active { return lhs.value.active }
            return lhs.key < rhs.key
        }.compactMap { key, state -> String? in
            guard let colon = key.firstIndex(of: ":") else { return nil }
            let pinKind = String(key[..<colon])
            let rawId = String(key[key.index(after: colon)...])
            guard !pinKind.isEmpty, !rawId.isEmpty, let base = pinBase(for: pinKind) else { return nil }
            let encId = encodeId(rawId, base: base)
            return "\(state.active ? "+" : "-")\(pinKind):\(encId)@\(encodeTs(state.ts))"
        }
        if !pinEntries.isEmpty {
            sections.append("N:\(pinEntries.joined(separator: ","))")
        }

        return sections.joined(separator: ";")
    }

    static func decode(_ payload: String, uid: String? = nil) -> CatalogLibrary? {
        if payload.isEmpty { return CatalogLibrary() }
        guard isAllowedPayload(payload) else { return nil }

        var lib = CatalogLibrary()

        func parseSetEntry(_ token: String, base: Int64) -> (id: String, state: SyncItemState)? {
            guard let sign = token.first, sign == "+" || sign == "-",
                  let at = token.lastIndex(of: "@") else { return nil }
            let idStart = token.index(after: token.startIndex)
            guard idStart < at else { return nil }
            let encId = String(token[idStart..<at])
            let tsTok = String(token[token.index(after: at)...])
            guard let rawId = decodeId(encId, base: base),
                  let ts = decodeTs(tsTok) else { return nil }
            return (rawId, SyncItemState(active: sign == "+", ts: ts))
        }

        func fillSet(_ body: String, base: Int64, into meta: inout [String: SyncItemState]) {
            for part in body.split(separator: ",", omittingEmptySubsequences: false) where !part.isEmpty {
                if let parsed = parseSetEntry(String(part), base: base) {
                    meta[parsed.id] = parsed.state
                }
            }
        }

        for section in payload.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = section.firstIndex(of: ":") else { return nil }
            let code = String(section[..<colon])
            let body = String(section[section.index(after: colon)...])
            switch code {
            case "L": fillSet(body, base: TuneCatalogID.syntheticTrackBase, into: &lib.likedTracksMeta)
            case "D": fillSet(body, base: TuneCatalogID.syntheticTrackBase, into: &lib.dislikedTracksMeta)
            case "A": fillSet(body, base: TuneCatalogID.syntheticAlbumBase, into: &lib.likedAlbumsMeta)
            case "R": fillSet(body, base: TuneCatalogID.syntheticArtistBase, into: &lib.likedArtistsMeta)
            case "B": fillSet(body, base: TuneCatalogID.syntheticArtistBase, into: &lib.dislikedArtistsMeta)
            case "Q": fillSet(body, base: TuneCatalogID.syntheticPlaylistBase, into: &lib.likedPlaylistsMeta)
            case "P":
                for entry in body.split(separator: ",", omittingEmptySubsequences: false) where !entry.isEmpty {
                    guard let eq = entry.firstIndex(of: "=") else { continue }
                    let head = entry[..<eq]
                    let listPart = entry[entry.index(after: eq)...]
                    guard let at = head.lastIndex(of: "@") else { continue }
                    let wireKind = String(head[..<at])
                    let tsTok = String(head[head.index(after: at)...])
                    guard !wireKind.isEmpty, let ts = decodeTs(tsTok) else { continue }
                    let localKey = (uid?.isEmpty == false) ? "\(uid!):\(wireKind)" : wireKind
                    let tracks = listPart.isEmpty
                        ? []
                        : listPart.split(separator: ".").compactMap { decodeId(String($0), base: TuneCatalogID.syntheticTrackBase) }
                    lib.playlistMeta[localKey] = ts
                    if !tracks.isEmpty {
                        lib.playlistTracks[localKey] = tracks
                    }
                }
            case "N":
                for entry in body.split(separator: ",", omittingEmptySubsequences: false) where !entry.isEmpty {
                    guard let sign = entry.first, sign == "+" || sign == "-",
                          let at = entry.lastIndex(of: "@") else { continue }
                    let start = entry.index(after: entry.startIndex)
                    guard start < at else { continue }
                    let kindAndId = entry[start..<at]
                    let tsTok = String(entry[entry.index(after: at)...])
                    guard let colon2 = kindAndId.firstIndex(of: ":"),
                          let ts = decodeTs(tsTok) else { continue }
                    let pinKind = String(kindAndId[..<colon2])
                    let encId = String(kindAndId[kindAndId.index(after: colon2)...])
                    guard let base = pinBase(for: pinKind),
                          let rawId = decodeId(encId, base: base) else { continue }
                    lib.pinsMeta["\(pinKind):\(rawId)"] = SyncItemState(active: sign == "+", ts: ts)
                }
            default:
                return nil
            }
        }

        lib.rebuildActiveArrays()
        return lib
    }

    static func buildShards(payload: String) -> [(index: Int, title: String, description: String)] {
        if payload.isEmpty {
            let desc = "\(shardHeader(index: 0))\n\n[tune-sync:v1:1/1:]"
            return [(0, playlistTitle(index: 0), desc)]
        }

        var total = 1
        while true {
            let capacities = (0..<total).map { idx -> Int in
                let template = "\(shardHeader(index: idx))\n\n[tune-sync:v1:\(idx + 1)/\(total):]"
                return max(0, maxDescriptionLength - template.utf16.count)
            }
            if capacities.reduce(0, +) >= payload.utf16.count {
                var result: [(Int, String, String)] = []
                var cursor = payload.startIndex
                for idx in 0..<total {
                    let cap = capacities[idx]
                    var end = cursor
                    var utf16Used = 0
                    while end < payload.endIndex {
                        let next = payload.index(after: end)
                        let stepCost = payload[end..<next].utf16.count
                        if utf16Used + stepCost > cap { break }
                        utf16Used += stepCost
                        end = next
                    }
                    let chunk = String(payload[cursor..<end])
                    cursor = end
                    let desc = "\(shardHeader(index: idx))\n\n[tune-sync:v1:\(idx + 1)/\(total):\(chunk)]"
                    result.append((idx, playlistTitle(index: idx), desc))
                }
                return result
            }
            total += 1
        }
    }

    static func extractEnvelope(_ description: String) -> (part: Int, total: Int, chunk: String)? {
        let marker = "[tune-sync:v1:"
        guard let startRange = description.range(of: marker),
              let endBracket = description[startRange.upperBound...].firstIndex(of: "]") else {
            return nil
        }
        let inner = description[startRange.upperBound..<endBracket]
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let ratio = inner[..<colon]
        let chunk = String(inner[inner.index(after: colon)...])
        let parts = ratio.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let part = Int(parts[0]), let total = Int(parts[1]),
              part >= 1, total >= 1, part <= total else {
            return nil
        }
        return (part, total, chunk)
    }

    static func parseRemoteShards(_ shards: [Playlist], uid: String?) -> RemoteParseResult {
        guard !shards.isEmpty else { return .empty }
        let sorted = shards.sorted {
            let a = Int64($0.kind) ?? Int64.max
            let b = Int64($1.kind) ?? Int64.max
            return a != b ? a < b : $0.kind < $1.kind
        }

        var missingEnvelope = false
        var parsed: [(shard: Playlist, part: Int, total: Int, chunk: String)] = []
        for shard in sorted {
            if let desc = shard.description, let env = extractEnvelope(desc) {
                parsed.append((shard, env.part, env.total, env.chunk))
            } else {
                missingEnvelope = true
            }
        }

        guard let firstPart = parsed.first(where: { $0.part == 1 }) else {
            return .incomplete("Не найдена часть 1")
        }

        let expectedTotal = firstPart.total
        var byPart: [Int: (shard: Playlist, chunk: String)] = [:]
        var duplicateSinglePayloads: [String] = []
        var duplicatesDetected = false
        var needsCleanup = missingEnvelope

        for item in parsed {
            if item.total != expectedTotal {
                needsCleanup = true
                if item.part == 1 && item.total == 1 {
                    duplicateSinglePayloads.append(item.chunk)
                }
                continue
            }
            if byPart[item.part] == nil {
                byPart[item.part] = (item.shard, item.chunk)
            } else {
                duplicatesDetected = true
                needsCleanup = true
                if item.part == 1 && item.total == 1 {
                    duplicateSinglePayloads.append(item.chunk)
                }
            }
        }

        for part in 1...expectedTotal where byPart[part] == nil {
            return .incomplete("Не хватает части \(part)/\(expectedTotal)")
        }

        let primaryPayload = (1...expectedTotal).compactMap { byPart[$0]?.chunk }.joined()
        guard let primaryLib = decode(primaryPayload, uid: uid) else {
            return .incomplete("Повреждён payload")
        }

        var libs = [primaryLib]
        for extraPayload in duplicateSinglePayloads {
            if let extraLib = decode(extraPayload, uid: uid) {
                libs.append(extraLib)
            }
        }
        return .ready(libraries: libs, duplicatesDetected: duplicatesDetected, needsCleanup: needsCleanup)
    }
}

/// Потокобезопасное хранилище локальной медиатеки Каталога Tune (привязано к uid аккаунта).
final class CatalogLibraryStore {
    static let shared = CatalogLibraryStore()

    private let lock = NSLock()
    private var uid: String?
    private var library = CatalogLibrary()
    var onMutation: ((String) -> Void)?

    private init() {}

    private static func fileName(for uid: String) -> String {
        "catalog-library-\(Storage.hash(uid)).json"
    }

    func load(uid: String) {
        var loaded: CatalogLibrary = Storage.load(Self.fileName(for: uid)) ?? CatalogLibrary()
        let migrated = loaded.ensureMigrated()
        lock.lock()
        self.uid = uid
        self.library = loaded
        lock.unlock()
        if migrated, !uid.isEmpty {
            Storage.save(loaded, Self.fileName(for: uid))
        }
    }

    func clearInMemory() {
        lock.lock()
        uid = nil
        library = CatalogLibrary()
        lock.unlock()
    }

    private func ensureLoaded(uid: String?) {
        guard let uid, !uid.isEmpty else { return }
        lock.lock()
        let needsLoad = self.uid != uid
        lock.unlock()
        if needsLoad {
            load(uid: uid)
        }
    }

    private func mutate<R>(_ block: (inout CatalogLibrary) -> R) -> R {
        lock.lock()
        let result = block(&library)
        let activeUID = uid
        let snapshot = library
        lock.unlock()
        if let activeUID, !activeUID.isEmpty {
            Storage.save(snapshot, Self.fileName(for: activeUID))
            onMutation?(activeUID)
        }
        return result
    }

    private func read<R>(_ block: (CatalogLibrary) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return block(library)
    }

    func snapshot(uid: String? = nil) -> CatalogLibrary {
        ensureLoaded(uid: uid)
        return read { $0 }
    }

    @discardableResult
    func ensureMigrated(uid: String, now: Int64 = TuneSyncCodec.nowSeconds()) -> Bool {
        ensureLoaded(uid: uid)
        lock.lock()
        let migrated = library.ensureMigrated(now: now)
        let snapshot = library
        lock.unlock()
        if migrated, !uid.isEmpty {
            Storage.save(snapshot, Self.fileName(for: uid))
        }
        return migrated
    }

    func applyRemoteMerge(
        uid: String,
        mergeWith remotes: [CatalogLibrary],
        now: Int64 = TuneSyncCodec.nowSeconds()
    ) -> (merged: CatalogLibrary, changedLocal: Bool, needsPush: Bool) {
        ensureLoaded(uid: uid)
        lock.lock()
        let initialLocal = library
        var working = library
        _ = working.ensureMigrated(now: now)
        var anyChangedLocal = working != initialLocal
        for remote in remotes {
            let res = CatalogLibrary.merge(local: working, remote: remote, now: now)
            working = res.merged
            if res.changedLocal { anyChangedLocal = true }
        }
        let needsPush: Bool
        if let primaryRemote = remotes.first {
            needsPush = TuneSyncCodec.encode(working, uid: uid, now: now) != TuneSyncCodec.encode(primaryRemote, uid: uid, now: now)
        } else {
            needsPush = working.hasActiveData
        }
        if anyChangedLocal {
            self.library = working
        }
        lock.unlock()
        if anyChangedLocal, !uid.isEmpty {
            Storage.save(working, Self.fileName(for: uid))
        }
        return (working, anyChangedLocal, needsPush)
    }

    var likedTracks: [String] {
        guard Settings.catalog else { return [] }
        return read(\.likedTracks)
    }

    var dislikedTracks: [String] {
        guard Settings.catalog else { return [] }
        return read(\.dislikedTracks)
    }

    var likedAlbums: [String] {
        guard Settings.catalog else { return [] }
        return read(\.likedAlbums)
    }

    var likedArtists: [String] {
        guard Settings.catalog else { return [] }
        return read(\.likedArtists)
    }

    var dislikedArtists: [String] {
        guard Settings.catalog else { return [] }
        return read(\.dislikedArtists)
    }

    var likedPlaylists: [String] {
        guard Settings.catalog else { return [] }
        return read(\.likedPlaylists)
    }

    var pins: [String] {
        guard Settings.catalog else { return [] }
        return read(\.pins)
    }

    func playlistTracks(owner: String, kind: String) -> [String] {
        guard Settings.catalog else { return [] }
        let key = "\(owner):\(kind)"
        return read { $0.playlistTracks[key] ?? [] }
    }

    func setTrackLiked(_ id: String, _ liked: Bool) {
        mutate { $0.setTrackLiked(id, liked) }
    }

    func setTrackDisliked(_ id: String, _ disliked: Bool) {
        mutate { $0.setTrackDisliked(id, disliked) }
    }

    func setAlbumLiked(_ id: String, _ liked: Bool) {
        mutate { $0.setAlbumLiked(id, liked) }
    }

    func setArtistLiked(_ id: String, _ liked: Bool) {
        mutate { $0.setArtistLiked(id, liked) }
    }

    func setArtistDisliked(_ id: String, _ disliked: Bool) {
        mutate { $0.setArtistDisliked(id, disliked) }
    }

    func setPlaylistLiked(_ kind: String, _ liked: Bool) {
        mutate { $0.setPlaylistLiked(kind, liked) }
    }

    func setPin(_ key: String, pinned: Bool) {
        mutate { $0.setPin(key, pinned: pinned) }
    }

    @discardableResult
    func addPlaylistTracks(_ ids: [String], owner: String, kind: String, atEnd: Bool = false) -> Int {
        mutate { $0.addPlaylistTracks(ids, to: "\(owner):\(kind)", atEnd: atEnd) }
    }

    @discardableResult
    func removePlaylistTrack(_ trackID: String, owner: String, kind: String) -> Bool {
        mutate { $0.removePlaylistTrack(trackID, from: "\(owner):\(kind)") }
    }

    func movePlaylistTrack(_ trackID: String, owner: String, kind: String, before nextID: String?) {
        mutate { $0.movePlaylistTrack(trackID, in: "\(owner):\(kind)", before: nextID) }
    }

    func clearPlaylist(owner: String, kind: String) {
        mutate { $0.clearPlaylist("\(owner):\(kind)") }
    }
}
