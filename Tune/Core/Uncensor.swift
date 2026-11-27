import Foundation

/// Без цензуры (FckCensor) и дополнительный каталог Tune (`tune-music/tune-catalog-data`).
/// Списки хранятся отдельно на диске, обновляются в фоне и объединяются динамически по настройкам.
final class Uncensor {
    static let shared = Uncensor()
    static let changed = Notification.Name("tune.uncensorChanged")

    private static let mirrors = [
        "https://raw.githubusercontent.com/Hazzz895/FckCensorData/refs/heads/main/",
        "https://cdn.jsdelivr.net/gh/Hazzz895/FckCensorData@main/",
    ]
    private static let catalogMirrors = [
        "https://raw.githubusercontent.com/tune-music/tune-catalog-data/main/",
        "https://cdn.jsdelivr.net/gh/tune-music/tune-catalog-data@main/",
    ]
    private static let catalogRefsPrefix = "https://raw.githubusercontent.com/tune-music/tune-catalog-data/refs/heads/main/"
    private static let fckTTL: TimeInterval = 3600
    private static let fckRetry: TimeInterval = 600
    private static let catalogTTL: TimeInterval = 120
    private static let catalogRetry: TimeInterval = 60

    private let state = CatalogState()
    private let lock = NSLock()
    private var fckMirror = UserDefaults.standard.integer(forKey: "uncensorMirror")
    private var catalogMirror = UserDefaults.standard.integer(forKey: "catalogMirror")
    private var loadingFck = false
    private var loadingCatalog = false
    private var started = false
    private var lastCatalogFetch: Date?
    private let fckCache = Storage.support.appendingPathComponent("uncensor.json")
    private let catalogCache = Storage.support.appendingPathComponent("tune-catalog.json")
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    var version: UInt64 { state.version }
    var hasFckData: Bool { state.hasFckData }
    var hasCatalogData: Bool { state.hasCatalogData }

    private var current: CatalogList? {
        state.current(uncensorEnabled: Settings.uncensor, catalogEnabled: Settings.catalog)
    }

    private func autoOn(_ id: String) -> Bool {
        MetadataOverrides.shared.value(.track, id)?.usePlugin != false
    }

    /// Читает сохранённые списки и запускает фоновое обновление FckCensor и Каталога Tune.
    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            var fckAge = TimeInterval.infinity
            if let data = try? Data(contentsOf: fckCache), let root = JSON.parse(data).dict {
                state.setFck(root)
                let modified = (try? FileManager.default.attributesOfItem(atPath: fckCache.path)[.modificationDate]) as? Date
                fckAge = modified.map { Date().timeIntervalSince($0) } ?? .infinity
            }
            if let data = try? Data(contentsOf: catalogCache), let root = JSON.parse(data).dict {
                state.setCatalog(root)
            }
            await postChanged()

            // Независимый цикл FckCensor: сразу если старше часа, затем раз в час.
            Task.detached(priority: .utility) { [self] in
                if fckAge <= Self.fckTTL {
                    let wait = max(0, Self.fckTTL - fckAge)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                while !Task.isCancelled {
                    let ok = await refreshFck()
                    let delay = ok ? Self.fckTTL : Self.fckRetry
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            // Независимый цикл Каталога Tune: сразу при запуске и каждые 120 секунд.
            Task.detached(priority: .utility) { [self] in
                while !Task.isCancelled {
                    let ok = await refreshCatalog()
                    let delay = ok ? Self.catalogTTL : Self.catalogRetry
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    func refresh() async {
        _ = await refreshFck()
    }

    @discardableResult
    func refreshFck() async -> Bool {
        lock.lock()
        if loadingFck {
            lock.unlock()
            return false
        }
        loadingFck = true
        let first = fckMirror
        lock.unlock()
        defer {
            lock.lock()
            loadingFck = false
            lock.unlock()
        }
        guard let (data, root, index) = await fetchList(mirrors: Self.mirrors, first: first, bustCache: false) else {
            return false
        }
        let previous = try? Data(contentsOf: fckCache)
        try? data.write(to: fckCache, options: .atomic)
        lock.lock()
        fckMirror = index
        lock.unlock()
        UserDefaults.standard.set(index, forKey: "uncensorMirror")
        if previous != data || !state.hasFckData {
            state.setFck(root)
            await invalidateAndNotify()
        }
        return true
    }

    @discardableResult
    func refreshCatalog() async -> Bool {
        lock.lock()
        if loadingCatalog {
            lock.unlock()
            return false
        }
        loadingCatalog = true
        let first = catalogMirror
        lock.unlock()
        defer {
            lock.lock()
            loadingCatalog = false
            lock.unlock()
        }
        guard let (data, root, index) = await fetchList(mirrors: Self.catalogMirrors, first: first, bustCache: true) else {
            return false
        }
        let previous = try? Data(contentsOf: catalogCache)
        try? data.write(to: catalogCache, options: .atomic)
        lock.lock()
        catalogMirror = index
        lastCatalogFetch = Date()
        lock.unlock()
        UserDefaults.standard.set(index, forKey: "catalogMirror")
        if previous != data || !state.hasCatalogData {
            state.setCatalog(root)
            await invalidateAndNotify()
        }
        return true
    }

    func refreshCatalogIfNeeded() {
        lock.lock()
        let last = lastCatalogFetch
        lock.unlock()
        if let last, Date().timeIntervalSince(last) < Self.catalogTTL { return }
        Task.detached(priority: .utility) { [self] in
            _ = await self.refreshCatalog()
        }
    }

    func notifyChanged() {
        state.bumpVersion()
        Task {
            await invalidateAndNotify()
        }
    }

    private func invalidateAndNotify() async {
        await SearchCache.shared.clearAll()
        await postChanged()
    }

    @MainActor
    private func postChanged() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func fetchList(mirrors: [String], first: Int, bustCache: Bool) async -> (Data, [String: Any], Int)? {
        var order = [first]
        for index in mirrors.indices where index != first {
            order.append(index)
        }
        let stamp = Int(Date().timeIntervalSince1970)
        for index in order where mirrors.indices.contains(index) {
            var rawURL = mirrors[index] + "list_v2.json"
            if bustCache, rawURL.hasPrefix("https://raw.githubusercontent.com/") {
                rawURL += "?t=\(stamp)"
            }
            guard let url = URL(string: rawURL) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = bustCache ? .reloadIgnoringLocalCacheData : .reloadRevalidatingCacheData
            if bustCache {
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            }
            guard let (data, response) = try? await http.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = JSON.parse(data).dict
            else { continue }
            return (data, root, index)
        }
        return nil
    }

    /// Ссылки на версию трека из Каталога Tune или FckCensor.
    func files(for id: String) -> [URL] {
        if let local = localAudio(id) { return [local] }
        guard autoOn(id), let raw = current?.files[id] else { return [] }
        let full = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://" + raw
        lock.lock()
        let preferredFck = fckMirror
        let preferredCat = catalogMirror
        lock.unlock()
        let out: [String]
        if full.hasPrefix(Self.mirrors[0]) {
            let rest = String(full.dropFirst(Self.mirrors[0].count))
            let ordered = preferredFck == 1 ? [Self.mirrors[1], Self.mirrors[0]] : [Self.mirrors[0], Self.mirrors[1]]
            out = ordered.map { $0 + rest }
        } else if full.hasPrefix(Self.catalogMirrors[0]) {
            let rest = String(full.dropFirst(Self.catalogMirrors[0].count))
            let ordered = preferredCat == 1 ? [Self.catalogMirrors[1], Self.catalogMirrors[0]] : [Self.catalogMirrors[0], Self.catalogMirrors[1]]
            out = ordered.map { $0 + rest }
        } else if full.hasPrefix(Self.catalogRefsPrefix) {
            let rest = String(full.dropFirst(Self.catalogRefsPrefix.count))
            let ordered = preferredCat == 1 ? [Self.catalogMirrors[1], Self.catalogMirrors[0]] : [Self.catalogMirrors[0], Self.catalogMirrors[1]]
            out = ordered.map { $0 + rest }
        } else {
            out = [full]
        }
        return out.compactMap { URL(string: $0) }
    }

    /// Треки FckCensor, у которых есть файл (исключая синтетические ID Каталога Tune).
    func fileIds() -> [String] {
        guard let files = state.fckOnly(uncensorEnabled: Settings.uncensor)?.files else { return [] }
        return files.keys.filter { !TuneCatalogID.isSyntheticTrack($0) }
    }

    /// Значок «T» — ТОЛЬКО когда Каталог Tune включён и у трека есть файл именно в catalogList.files.
    func isCatalogTrack(_ id: String) -> Bool {
        state.isCatalogTrack(id, catalogEnabled: Settings.catalog, autoOn: autoOn(id))
    }

    /// Значок замка FckCensor — исключает треки Каталога Tune.
    func has(_ id: String) -> Bool {
        if isCatalogTrack(id) { return false }
        if localAudio(id) != nil { return true }
        return state.hasFckCensor(id, uncensorEnabled: Settings.uncensor, catalogEnabled: Settings.catalog, autoOn: autoOn(id))
    }

    /// Есть ли аудиофайл (свой, FckCensor или Каталог Tune) для воспроизведения и скачивания.
    func hasAudio(_ id: String) -> Bool {
        localAudio(id) != nil || state.hasAudio(id, uncensorEnabled: Settings.uncensor, catalogEnabled: Settings.catalog, autoOn: autoOn(id))
    }

    func displaysCatalogBadge(for track: Track) -> Bool {
        guard Settings.catalog else { return false }
        if hasCatalogData { return isCatalogTrack(track.id) }
        return track.isCatalog
    }

    func displaysUncensoredBadge(for track: Track) -> Bool {
        if displaysCatalogBadge(for: track) { return false }
        if localAudio(track.id) != nil { return true }
        guard Settings.uncensor else { return false }
        if hasFckData { return has(track.id) }
        return track.uncensored
    }

    func localAudio(_ id: String) -> URL? {
        guard let name = MetadataOverrides.shared.value(.track, id)?.audio,
              let url = MetadataOverrides.file(name), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Трек из ответа Яндекса с подменой; nil — подменять нечего.
    func patch(track: [String: Any], id: String) -> (fields: [String: Any], file: Bool, catalog: Bool)? {
        let user = MetadataOverrides.shared.value(.track, id)
        let list = user?.usePlugin == false ? nil : current
        let spoof = list?.tracks[id]
        let catalog = isCatalogTrack(id)
        let fck = has(id)
        let playable = user?.audio != nil ? localAudio(id) != nil : list?.files[id] != nil
        if spoof == nil && !playable && user == nil { return nil }
        var out = track
        if let spoof { CatalogIndex.apply(&out, spoof) }
        if let user { Self.applyUser(user, to: &out) }
        if playable {
            // Удалённый или закрытый в Яндексе трек с файлом снова играет.
            out["available"] = true
            out["error"] = nil
        }
        return (out, fck, catalog)
    }

    func patch(album: [String: Any], id: String) -> [String: Any]? {
        let user = MetadataOverrides.shared.value(.album, id)
        let spoof = user?.usePlugin == false ? nil : current?.albums[id]
        guard spoof != nil || user != nil else { return nil }
        var out = album
        if let spoof { CatalogIndex.apply(&out, spoof) }
        if let user { Self.applyUser(user, to: &out) }
        return out
    }

    func patch(artist: JSON) -> JSON {
        guard let id = artist["id"].idText, var fields = artist.dict else { return artist }
        let user = MetadataOverrides.shared.value(.artist, id)
        let spoof = user?.usePlugin == false ? nil : current?.artists[id]
        guard spoof != nil || user != nil else { return artist }
        if let spoof { CatalogIndex.apply(&fields, spoof) }
        if let user {
            if !user.title.isEmpty { fields["name"] = user.title }
            if let cover = user.coverURI {
                fields["ogImage"] = cover
                fields["cover"] = ["uri": cover]
                fields["coverUri"] = cover
            }
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

    /// Треки альбома по дискам, как в списке: туда возвращаются удалённые Яндексом и добавленные Каталогом.
    func volumes(album id: String) -> [[String]]? {
        if let disks = customDisks(album: id) { return disks }
        if MetadataOverrides.shared.value(.album, id)?.usePlugin == false { return nil }
        guard let volumes = current?.albums[id]?["volumes"] as? [Any] else { return nil }
        let disks = volumes.compactMap { disk in (disk as? [Any])?.compactMap { CatalogIndex.id(of: $0) } }
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

    func search(_ query: String, tracks: Bool, albums: Bool, artists: Bool = false, playlists: Bool = false)
        -> (tracks: [JSON], albums: [JSON], artists: [JSON], playlists: [(kind: String, fields: [String: Any])]) {
        state.search(
            query,
            tracks: tracks,
            albums: albums,
            artists: artists,
            playlists: playlists,
            uncensorEnabled: Settings.uncensor,
            catalogEnabled: Settings.catalog
        )
    }

    func catalogTrack(_ id: String) -> JSON? {
        guard hasAudio(id) else { return nil }
        return state.catalogTrack(
            id,
            uncensorEnabled: Settings.uncensor,
            catalogEnabled: Settings.catalog,
            allowWithoutFile: localAudio(id) != nil
        )
    }

    func catalogAlbum(_ id: String) -> JSON? {
        state.catalogAlbum(id, uncensorEnabled: Settings.uncensor, catalogEnabled: Settings.catalog)
    }

    func catalogArtist(_ id: String) -> (json: JSON, trackIDs: [String], albumIDs: [String])? {
        state.catalogArtist(id, uncensorEnabled: Settings.uncensor, catalogEnabled: Settings.catalog)
    }

    func catalogPlaylist(_ kind: String) -> (fields: [String: Any], trackIDs: [String])? {
        state.catalogPlaylist(kind, catalogEnabled: Settings.catalog)
    }
}
