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

    private static func pushFront(_ list: inout [String], _ id: String) {
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
    }

    mutating func setTrackLiked(_ id: String, _ liked: Bool) {
        if liked {
            dislikedTracks.removeAll { $0 == id }
            Self.pushFront(&likedTracks, id)
        } else {
            likedTracks.removeAll { $0 == id }
        }
    }

    mutating func setTrackDisliked(_ id: String, _ disliked: Bool) {
        if disliked {
            likedTracks.removeAll { $0 == id }
            Self.pushFront(&dislikedTracks, id)
        } else {
            dislikedTracks.removeAll { $0 == id }
        }
    }

    mutating func setAlbumLiked(_ id: String, _ liked: Bool) {
        if liked {
            Self.pushFront(&likedAlbums, id)
        } else {
            likedAlbums.removeAll { $0 == id }
        }
    }

    mutating func setArtistLiked(_ id: String, _ liked: Bool) {
        if liked {
            dislikedArtists.removeAll { $0 == id }
            Self.pushFront(&likedArtists, id)
        } else {
            likedArtists.removeAll { $0 == id }
        }
    }

    mutating func setArtistDisliked(_ id: String, _ disliked: Bool) {
        if disliked {
            likedArtists.removeAll { $0 == id }
            Self.pushFront(&dislikedArtists, id)
        } else {
            dislikedArtists.removeAll { $0 == id }
        }
    }

    mutating func setPlaylistLiked(_ kind: String, _ liked: Bool) {
        if liked {
            Self.pushFront(&likedPlaylists, kind)
        } else {
            likedPlaylists.removeAll { $0 == kind }
        }
    }

    /// Возвращает число реально добавленных новых треков (без дубликатов).
    @discardableResult
    mutating func addPlaylistTracks(_ ids: [String], to key: String, atEnd: Bool = false) -> Int {
        var list = playlistTracks[key] ?? []
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
        return Set(list).subtracting(before).count
    }

    mutating func removePlaylistTrack(_ trackID: String, from key: String) -> Bool {
        guard var list = playlistTracks[key] else { return false }
        let before = list.count
        list.removeAll { $0 == trackID }
        if list.isEmpty {
            playlistTracks.removeValue(forKey: key)
        } else {
            playlistTracks[key] = list
        }
        return list.count != before
    }

    mutating func movePlaylistTrack(_ trackID: String, in key: String, before nextID: String?) {
        guard var list = playlistTracks[key], let from = list.firstIndex(of: trackID) else { return }
        list.remove(at: from)
        if let nextID, let target = list.firstIndex(of: nextID) {
            list.insert(trackID, at: target)
        } else {
            list.append(trackID)
        }
        playlistTracks[key] = list
    }

    mutating func clearPlaylist(_ key: String) {
        playlistTracks.removeValue(forKey: key)
    }

    mutating func setPin(_ key: String, pinned: Bool) {
        if pinned {
            Self.pushFront(&pins, key)
        } else {
            pins.removeAll { $0 == key }
        }
    }
}

/// Потокобезопасное хранилище локальной медиатеки Каталога Tune (привязано к uid аккаунта).
final class CatalogLibraryStore {
    static let shared = CatalogLibraryStore()

    private let lock = NSLock()
    private var uid: String?
    private var library = CatalogLibrary()

    private init() {}

    private static func fileName(for uid: String) -> String {
        "catalog-library-\(Storage.hash(uid)).json"
    }

    func load(uid: String) {
        let loaded: CatalogLibrary = Storage.load(Self.fileName(for: uid)) ?? CatalogLibrary()
        lock.lock()
        self.uid = uid
        self.library = loaded
        lock.unlock()
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
