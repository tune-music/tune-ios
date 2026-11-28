import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ListKind: Hashable {
    case likes
    case downloads
    case history
    case disliked
    case playlist(Playlist)
    case album(String)
    case artist(String, String)
    case artistFamiliar(String, String, Bool)
}

/// Порядок треков на странице.
enum TrackSort: String, CaseIterable, Identifiable {
    case original, title, artist, newest, oldest

    var id: String { rawValue }

    var name: String {
        switch self {
        case .original: return "Как в списке"
        case .title: return "По названию"
        case .artist: return "По исполнителю"
        case .newest: return "Сначала новые"
        case .oldest: return "Сначала старые"
        }
    }
}

@MainActor
final class TrackListModel: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var title = ""
    @Published var subtitle = ""
    @Published var cover: String?
    @Published var loading = false
    @Published var error: String?
    /// Подробности альбома: исполнитель, лейбл, диски.
    @Published var album: AlbumPage?
    /// Другие альбомы того же исполнителя.
    @Published var more: [Card] = []
    /// Автор и описание плейлиста.
    @Published var info: PlaylistPage?
    /// История: подпись дня у первого трека, который слушали в этот день.
    @Published var days: [String: String] = [:]
    @Published var historySources: [String: String] = [:]
    @Published var filters: [TrackFilter] = []
    private var likesLoading = false
    @Published private(set) var likesError: String?
    private var loaded = false
    private var localLikeIDs = Set<String>()
    private var cachedLikesLoaded = false
    private var staleLikedTracks = Set<String>()
    private static var filterCache: [String: [TrackFilter]] = [:]
    private static var filtersByPlace: [String: [TrackFilter]] = [:]
    private var filterTask: Task<Void, Never>?
    private var filterKey: String?

    init(kind: ListKind) {
        self.kind = kind
        switch kind {
        case .playlist(let playlist):
            title = playlist.title
            cover = playlist.cover
        case .artist(_, let name), .artistFamiliar(_, let name, _):
            title = name
        default:
            break
        }
        if !Demo.on, let place = Self.filterPlace(for: kind) {
            if let mem = Self.filtersByPlace[place] {
                filters = mem
            } else if let disk = Storage.load(Self.filterCacheFile(for: place), as: [TrackFilter].self) {
                Self.filtersByPlace[place] = disk
                filters = disk
            }
        }
    }

    private let kind: ListKind

    func updateLocalLikes(_ local: [Track]) {
        let catalogLikes = Session.shared.catalogLikedTracksList()
        let combined = catalogLikes + local
        let newIDs = Set(combined.map(\.id))
        let excluded = localLikeIDs.union(newIDs)
        localLikeIDs = newIDs
        let rest = tracks.filter {
            !excluded.contains($0.id) && (Settings.catalog || !TuneCatalogID.isSyntheticTrack($0.id))
        }
        let updated = CatalogMerge.mergeTimedDesc(
            local: combined.map { (item: $0, date: $0.addedAt) },
            remote: rest.map { (item: $0, date: $0.addedAt) },
            id: { $0.id }
        )
        applyLikes(updated)
    }

    func metadataChanged(_ target: ReplacementTarget) {
        switch target.kind {
        case .track: staleLikedTracks.insert(target.id)
        case .album:
            staleLikedTracks.formUnion(tracks.filter { $0.albumId == target.id }.map(\.id))
        case .artist:
            staleLikedTracks.formUnion(tracks.filter { $0.artistList.contains { $0.id == target.id } }.map(\.id))
        }
    }

    /// Сохранённая копия списка: с неё страница открывается мгновенно и без сети.
    private struct Cached: Codable {
        var title: String
        var subtitle: String
        var cover: String?
        var tracks: [Track]
        var days: [String: String]? = nil
        var historySources: [String: String]? = nil
        var album: AlbumPage? = nil
    }

    private static func cacheName(_ kind: ListKind) -> String? {
        let key: String
        switch kind {
        case .playlist(let playlist): key = "playlist:" + playlist.id
        case .album(let id): key = "album:" + id
        case .artist(let id, _): key = "artist-tracks:" + id
        case .artistFamiliar(let id, _, let wave): key = "artist-familiar:\(id):\(wave)"
        case .history: key = "history"
        default: return nil
        }
        _ = Storage.lists
        return "Lists/" + Storage.hash(key) + ".json"
    }

    func load(_ kind: ListKind, force: Bool = false) async {
        if kind == .likes, likesLoading { return }
        if loaded && !force { return }
        let showLoading = tracks.isEmpty
        if loading != showLoading { loading = showLoading }
        if error != nil { error = nil }
        if tracks.isEmpty, !Demo.on, let name = Self.cacheName(kind) {
            let saved = await Task.detached(priority: .userInitiated) { Storage.load(name, as: Cached.self) }.value
            if let saved, tracks.isEmpty {
                tracks = saved.tracks
                days = saved.days ?? [:]
                historySources = saved.historySources ?? [:]
                album = saved.album
                if title.isEmpty { title = saved.title }
                if subtitle.isEmpty { subtitle = saved.subtitle }
                if cover == nil { cover = saved.cover }
                if loading { loading = false }
                loadFilters(for: kind)
            }
        }
        defer { if loading { loading = false } }
        do {
            switch kind {
            case .downloads:
                break
            case .likes:
                try await loadLikes()
            case .history:
                let page = try await API.shared.history()
                applyTracks(page.tracks)
                if days != page.days { days = page.days }
                if historySources != page.sources { historySources = page.sources }
            case .disliked:
                if Session.shared.profile == nil { await Session.shared.refresh() }
                var found: [Track] = []
                for chunk in Array(Session.shared.disliked).chunked(150) {
                    found += try await API.shared.tracks(ids: chunk)
                }
                applyTracks(found)
            case .playlist(let playlist):
                if title.isEmpty { title = playlist.title }
                if cover == nil { cover = playlist.cover }
                let page = try await API.shared.playlist(playlist)
                applyTracks(page.tracks)
                info = page
                if title.isEmpty { title = page.title }
                let nextCover = page.cover ?? playlist.cover
                if cover != nextCover { cover = nextCover }
            case .album(let id):
                let page = try await API.shared.album(id: id)
                if title != page.card.title { title = page.card.title }
                if subtitle != page.card.subtitle { subtitle = page.card.subtitle }
                if cover != page.card.cover { cover = page.card.cover }
                applyTracks(page.tracks)
                album = page
                if more.isEmpty, let artist = page.artist, !artist.id.isEmpty {
                    Task { [weak self] in
                        guard let info = try? await API.shared.artist(id: artist.id) else { return }
                        self?.more = (info.albums + info.singles).filter { $0.id != id }
                    }
                }
            case .artist(let id, let name):
                if title != name { title = name }
                applyTracks(try await API.shared.artistTracks(id: id))
            case .artistFamiliar(let id, let name, let wave):
                if title != name { title = name }
                applyTracks(try await API.shared.familiarTracks(artist: id, wave: wave))
            }
            loaded = true
            loadFilters(for: kind)
            if !Demo.on, !tracks.isEmpty, let name = Self.cacheName(kind) {
                let snapshot = Cached(title: title, subtitle: subtitle, cover: cover, tracks: tracks,
                                      days: kind == .history ? days : nil, historySources: kind == .history ? historySources : nil,
                                      album: album)
                Task.detached(priority: .utility) { Storage.save(snapshot, name) }
            }
            if case .playlist(let playlist) = kind { Downloads.shared.autoPlaylist(playlist, tracks) }
        } catch {
            if Task.isCancelled { return }
            if tracks.isEmpty {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Лайки: сначала сохранённый список, потом с сервера только то, чего в нём нет.
    @Published private(set) var showsLikesProgress = false

    private func loadLikes() async throws {
        likesLoading = true
        if likesError != nil { likesError = nil }
        defer {
            likesLoading = false
            if showsLikesProgress { showsLikesProgress = false }
        }
        do {
            try await fetchLikes()
        } catch {
            if !Task.isCancelled, !tracks.isEmpty { likesError = error.localizedDescription }
            throw error
        }
    }

    private func fetchLikes() async throws {
        if !cachedLikesLoaded, !Demo.on {
            cachedLikesLoaded = true
            let cached = await Task.detached(priority: .userInitiated) { Storage.load("likes-tracks.json", as: [Track].self) }.value
            if let cached, tracks.allSatisfy({ localLikeIDs.contains($0.id) }) {
                tracks = cached.filter { Settings.catalog || !TuneCatalogID.isSyntheticTrack($0.id) }
                updateLocalLikes(Session.shared.localLikedTracks)
                loading = false
            } else if tracks.isEmpty {
                updateLocalLikes(Session.shared.localLikedTracks)
                if !tracks.isEmpty { loading = false }
            }
        }
        if Session.shared.profile == nil {
            await Session.shared.refresh()
        }
        guard let uid = Session.shared.profile?.uid else { throw APIError.network("") }
        var seen = Set<String>()
        let entries = try await API.shared.likedEntries(uid: uid).filter {
            !Session.shared.hasPendingRestoredUnlike($0.id) && seen.insert($0.id).inserted
        }
        try Task.checkCancellation()
        guard Session.shared.profile?.uid == uid else { return }
        let ids = entries.map(\.id)
        var known: [String: Track] = [:]
        for track in tracks where !staleLikedTracks.contains(track.id) { known[track.id] = track }
        let publishPages = tracks.isEmpty
        if publishPages { showsLikesProgress = true }
        var ordered: [Track] = []
        // Первую страницу показываем как можно раньше, остальное догружаем порциями.
        let first = Array(entries.prefix(60))
        let pages = [first] + Array(entries.dropFirst(first.count)).chunked(150)
        for page in pages where !page.isEmpty {
            let missing = page.map(\.id).filter { known[$0] == nil }
            for track in try await API.shared.tracks(ids: missing) { known[track.id] = track }
            try Task.checkCancellation()
            guard Session.shared.profile?.uid == uid else { return }
            let items: [Track] = page.compactMap { entry in
                guard var track = known[entry.id] else { return nil }
                track.addedAt = entry.addedAt ?? track.addedAt
                return track
            }
            ordered.append(contentsOf: items)
            if publishPages, !items.isEmpty {
                tracks.append(contentsOf: items)
                loading = false
            }
        }
        let local = Session.shared.catalogLikedTracksList() + Session.shared.localLikedTracks
        var seenLocal = Set<String>()
        let uniqueLocal = local.filter { seenLocal.insert($0.id).inserted }
        localLikeIDs = Set(uniqueLocal.map(\.id))
        Session.shared.setLiked(ids)
        let mergedAll = CatalogMerge.mergeTimedDesc(
            local: uniqueLocal.map { (item: $0, date: $0.addedAt) },
            remote: ordered.filter { !localLikeIDs.contains($0.id) }.map { (item: $0, date: $0.addedAt) },
            id: { $0.id }
        )
        applyLikes(mergedAll)
        staleLikedTracks.removeAll()
        Downloads.shared.auto(ordered)
        if !Demo.on {
            Task.detached(priority: .utility) { Storage.save(ordered, "likes-tracks.json") }
        }
    }

    private func applyLikes(_ ordered: [Track]) {
        applyTracks(ordered)
    }

    private func applyTracks(_ fresh: [Track]) {
        guard fresh != tracks else { return }
        if tracks.isEmpty {
            tracks = fresh
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { tracks = fresh }
        }
    }

    private static func filterPlace(for kind: ListKind, albumKind: String? = nil) -> String? {
        switch kind {
        case .likes: return "likes"
        case .downloads: return "downloads"
        case .history: return "history"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        case .album(let id):
            if albumKind == "podcast" || albumKind == "audiobook" { return nil }
            return "album:\(id)"
        case .artist(let id, _): return "artist-tracks:\(id)"
        case .artistFamiliar(let id, _, let wave): return "artist-familiar:\(id):\(wave)"
        case .disliked: return nil
        }
    }

    private static func filterCacheFile(for place: String) -> String {
        _ = Storage.lists
        return "Lists/filters-" + Storage.hash(place) + ".json"
    }

    func loadFilters(for kind: ListKind, sourceTracks: [Track]? = nil) {
        guard let place = Self.filterPlace(for: kind, albumKind: album?.kind) else {
            if !filters.isEmpty { filters = [] }
            return
        }
        let source = sourceTracks ?? tracks
        var seen = Set<String>()
        let ids = source.map(\.id).filter {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && !TuneCatalogID.isSyntheticTrack($0) && seen.insert($0).inserted
        }
        let cacheKey = "\(place):\(ids.count):\(ids.first ?? ""):\(ids.last ?? "")"
        if filterKey == cacheKey { return }
        filterKey = cacheKey
        filterTask?.cancel()
        guard ids.count >= 4 else {
            if !source.isEmpty {
                Self.filtersByPlace[place] = []
                if !filters.isEmpty { filters = [] }
            }
            return
        }
        if let cached = Self.filterCache[cacheKey] {
            if filters != cached { filters = cached }
            return
        }
        guard !Connectivity.shared.offline, !Session.shared.offline else { return }
        filterTask = Task { [weak self] in
            guard let loaded = try? await API.shared.trackFilters(ids: ids), !Task.isCancelled else { return }
            guard let self, self.filterKey == cacheKey else { return }
            Self.filterCache[cacheKey] = loaded
            Self.filtersByPlace[place] = loaded
            if self.filters != loaded { self.filters = loaded }
            if !Demo.on {
                let file = Self.filterCacheFile(for: place)
                Task.detached(priority: .utility) { Storage.save(loaded, file) }
            }
        }
    }

    func updateUploadedTrack(_ edited: Track, kind: ListKind) {
        guard tracks.contains(where: { $0.id == edited.id }) else { return }
        tracks = tracks.map {
            $0.id == edited.id ? $0.withUploadedMetadata(title: edited.title, artist: edited.artists) : $0
        }
        guard !Demo.on else { return }
        if kind == .likes {
            let snapshot = tracks.filter { !localLikeIDs.contains($0.id) }
            Task.detached(priority: .utility) { Storage.save(snapshot, "likes-tracks.json") }
        } else if let name = Self.cacheName(kind) {
            let snapshot = Cached(title: title, subtitle: subtitle, cover: cover, tracks: tracks,
                                  days: kind == .history ? days : nil, historySources: kind == .history ? historySources : nil,
                                  album: album)
            Task.detached(priority: .utility) { Storage.save(snapshot, name) }
        }
    }
}

@MainActor
private final class TrackListChromeState: ObservableObject {
    @Published var tone = Theme.tone
}

private struct TrackListChrome<Content: View>: View {
    @ObservedObject var chrome: TrackListChromeState
    let navTitle: NavTitleState
    let alwaysShown: Bool
    let searching: Bool
    let title: String
    let cover: String?
    let usesTone: Bool
    let content: Content

    var body: some View {
        content
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    Theme.background
                    LinearGradient(colors: [Theme.wash(chrome.tone), Theme.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 460)
                }
                .ignoresSafeArea()
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    NavBarTitle(state: navTitle, alwaysShown: alwaysShown, hidden: searching, title: title)
                }
            }
            .task(id: cover) {
                guard usesTone else {
                    if chrome.tone != Theme.tone { chrome.tone = Theme.tone }
                    return
                }
                let color = await ImageLoader.shared.tone(cover)
                withAnimation(.easeInOut(duration: 0.3)) { chrome.tone = color ?? Theme.tone }
            }
    }
}

/// Страница плейлиста, альбома, лайков, истории или скачанного: шапка с обложкой и список треков.
struct TrackListScreen: View {
    let kind: ListKind

    @StateObject private var model: TrackListModel

    init(kind: ListKind) {
        self.kind = kind
        _model = StateObject(wrappedValue: TrackListModel(kind: kind))
    }
    private var player: Player { Player.shared }
    private var downloads: Downloads { Downloads.shared }
    @State private var downloadEntries: [Downloads.Entry] = []
    @State private var hasDownloadQueue = false
    @State private var hasDownloadPanel = false
    private var session: Session { Session.shared }
    @State private var accountID: String?
    @State private var pageLiked = false
    @State private var dislikedIDs = Set<String>()
    @State private var familiarLikes: Set<String>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigate) private var navigate
    @State private var filter = ""
    @State private var searching = Demo.screen == "filter"
    @FocusState private var focused: Bool
    @State private var confirmRemove = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var choosingCover = false
    @State private var coverPhoto: PhotosPickerItem?
    @State private var uploadingCover = false
    @State private var importingAudio = false
    @State private var uploadingAudio = false
    @State private var name = ""
    @State private var sort = TrackSort.original
    @State private var onlyDownloaded = false
    @State private var selectedFilter: String? = nil
    /// Режим выбора нескольких треков.
    @State private var selecting = Demo.screen == "select"
    @State private var selected = Set<String>()
    /// Режим перестановки треков в своём плейлисте.
    @State private var reordering = false
    @State private var pickingMany = false
    /// Состояние шапки и тона вынесено из TrackListScreen, чтобы прокрутка и смена цвета
    /// не пересчитывали весь список треков.
    @State private var chrome = TrackListChromeState()
    @State private var navTitle = NavTitleState()
    /// Плейлист скачивается сам.
    @State private var auto = false
    @State private var prepared = false

    private var all: [Track] {
        switch kind {
        case .downloads: return downloadEntries.map(\.track)
        // Трек пропадает из списка, как только с него сняли дизлайк.
        case .disliked: return model.tracks.filter { dislikedIDs.contains($0.id) }
        default: return model.tracks
        }
    }

    private var activeFilterIDs: Set<String>? {
        guard let selectedFilter else { return nil }
        return model.filters.first(where: { $0.id == selectedFilter })?.trackIds
    }

    private var shown: [Track] {
        var list = all
        if onlyDownloaded { list = list.filter { downloads.has($0.id) } }
        if let activeFilterIDs { list = list.filter { activeFilterIDs.contains($0.id) } }
        let text = filter.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.artists.localizedCaseInsensitiveContains(text) }
        }
        switch sort {
        case .original: break
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: list.sort { $0.artists.localizedCaseInsensitiveCompare($1.artists) == .orderedAscending }
        case .newest, .oldest:
            var downloadDates: [String: Date] = [:]
            if kind == .downloads {
                for entry in downloadEntries { downloadDates[entry.track.id] = entry.date }
            }
            let dated = list.enumerated().map { index, track in
                (index: index, track: track, date: kind == .downloads ? downloadDates[track.id] : track.addedAt)
            }
            list = dated.sorted { a, b in
                switch (a.date, b.date) {
                case let (left?, right?) where left != right: return sort == .newest ? left > right : left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.index < b.index
                }
            }.map(\.track)
        }
        return list
    }

    private var sortOptions: [TrackSort] {
        let basic: [TrackSort] = [.original, .title, .artist]
        switch kind {
        case .downloads:
            return basic + [.newest, .oldest]
        case .playlist, .likes:
            return all.contains { $0.addedAt != nil } ? basic + [.newest, .oldest] : basic
        default:
            return basic
        }
    }

    /// Список показан как есть: без фильтра и своей сортировки.
    private var plainOrder: Bool {
        filter.isEmpty && sort == .original && !onlyDownloaded && selectedFilter == nil
    }

    private var chosen: [Track] {
        shown.filter { selected.contains($0.id) }
    }

    private var playlist: Playlist? {
        if case .playlist(let playlist) = kind { return playlist }
        return nil
    }

    private var own: Bool {
        guard let playlist, let accountID else { return false }
        return playlist.owner == accountID
    }

    private var context: PlayContext {
        switch kind {
        case .likes: return .various("Мне нравится")
        case .downloads: return .various("Скачанные треки")
        case .history: return .various("История")
        case .disliked: return .various("Не нравится")
        case .playlist(let playlist): return PlayContext(kind: "playlist", item: playlist.id, name: title)
        case .album(let id): return PlayContext(kind: "album", item: id, name: model.title)
        case .artist(let id, let name): return PlayContext(kind: "artist", item: id, name: name)
        case .artistFamiliar(let id, let name, let wave):
            return PlayContext(kind: "artist", item: "\(id):\(wave)", name: name)
        }
    }

    private var title: String {
        switch kind {
        case .likes: return "Мне нравится"
        case .downloads: return "Скачанные треки"
        case .history: return "История"
        case .disliked: return "Не нравится"
        case .playlist(let playlist): return model.title.isEmpty ? playlist.title : model.title
        case .artist(_, let name): return name
        case .artistFamiliar(_, _, let wave): return wave ? "Слушали в Волне" : "У вас в коллекции"
        case .album: return model.title
        }
    }

    private var kindName: String {
        switch kind {
        case .album:
            switch model.album?.kind {
            case "single": return "Сингл"
            case "compilation": return "Сборник"
            case "podcast": return "Подкаст"
            default: return "Альбом"
            }
        case .artist: return "Все треки"
        case .artistFamiliar(_, let name, _): return name
        case .history: return "Вы слушали"
        case .downloads: return "На устройстве"
        case .disliked: return "Скрыто из рекомендаций"
        default: return "Плейлист"
        }
    }

    private var cover: String? {
        model.cover ?? playlist?.cover
    }

    private var shareURL: URL? {
        switch kind {
        case .album(let id):
            return TuneCatalogID.isSyntheticAlbum(id) ? nil : URL(string: "https://music.yandex.ru/album/\(id)")
        case .playlist(let playlist):
            return playlist.shareURL
        default:
            return nil
        }
    }

    /// Сердечко есть у альбома и чужого плейлиста: оно добавляет их в коллекцию.
    private var liked: Bool? {
        switch kind {
        case .album: return pageLiked
        case .playlist: return own ? nil : pageLiked
        default: return nil
        }
    }

    private func toggleLike() {
        switch kind {
        case .album(let id): session.toggleAlbum(id)
        case .playlist(let playlist): session.togglePlaylist(playlist)
        default: break
        }
    }

    var body: some View {
        observedPage
            .onReceive(Session.shared.$localLikedTracks.removeDuplicates()) {
                if kind == .likes {
                    model.updateLocalLikes($0)
                } else if case .artistFamiliar(_, _, false) = kind {
                    let updated = Set($0.map(\.id))
                    if let familiarLikes, familiarLikes != updated {
                        Task { await model.load(kind, force: true) }
                    }
                    if familiarLikes != updated { familiarLikes = updated }
                }
            }
            .onReceive(Session.shared.$likedIds.map { $0.filter(TuneCatalogID.isSyntheticTrack) }.removeDuplicates()) { _ in
                if kind == .likes {
                    model.updateLocalLikes(Session.shared.localLikedTracks)
                }
            }
            .onReceive(downloads.$entries.removeDuplicates()) { entries in
                if (kind == .downloads || onlyDownloaded), downloadEntries != entries {
                    downloadEntries = entries
                    if kind == .downloads {
                        model.loadFilters(for: kind, sourceTracks: entries.map(\.track))
                    }
                }
            }
            .onChange(of: onlyDownloaded) { enabled in
                if enabled { downloadEntries = downloads.entries }
            }
            .onReceive(downloads.$queue.map { !$0.isEmpty }.removeDuplicates()) {
                if hasDownloadQueue != $0 { hasDownloadQueue = $0 }
            }
            .onReceive(downloadPanelVisibility) {
                if kind == .downloads, hasDownloadPanel != $0 { hasDownloadPanel = $0 }
            }
            .onReceive(NotificationCenter.default.publisher(for: Uploads.likesChanged)) { _ in
                if kind == .likes { Task { await model.load(kind, force: true) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: Session.restoredLikesSynced)) { _ in
                if kind == .likes || isArtistCollection { Task { await model.load(kind, force: true) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: Session.catalogLibrarySynced)) { _ in
                if kind == .likes {
                    model.updateLocalLikes(Session.shared.localLikedTracks)
                    Task { await model.load(kind, force: true) }
                } else if own {
                    Task { await model.load(kind, force: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Session.uploadedTrackEdited)) { note in
                guard let edited = note.object as? Track else { return }
                model.updateUploadedTrack(edited, kind: kind)
            }
            .onReceive(NotificationCenter.default.publisher(for: MetadataOverrides.changed)) { note in
                guard let target = note.object as? ReplacementTarget else { return }
                if kind == .likes { model.metadataChanged(target) }
                Task { await model.load(kind, force: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: Uncensor.changed)) { _ in
                if kind == .likes {
                    model.updateLocalLikes(Session.shared.localLikedTracks)
                }
                if kind != .downloads {
                    Task { await model.load(kind, force: true) }
                }
            }
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let files):
                    let destination = own ? playlist : nil
                    uploadingAudio = true
                    Task {
                        await Uploads.shared.add(files, to: destination)
                        uploadingAudio = false
                        await model.load(kind, force: true)
                    }
                case .failure(let error):
                    session.show(error.localizedDescription)
                }
            }
    }

    private var observedPage: some View {
        page
            .onReceive(session.$profile.map { $0?.uid }.removeDuplicates()) { uid in
                if playlist != nil, accountID != uid { accountID = uid }
            }
            .onReceive(session.$likedAlbums.removeDuplicates()) { ids in
                if case .album(let id) = kind, pageLiked != ids.contains(id) { pageLiked = ids.contains(id) }
            }
            .onReceive(session.$likedPlaylists.removeDuplicates()) { lists in
                if let playlist {
                    let liked = lists.contains { $0.id == playlist.id }
                    if pageLiked != liked { pageLiked = liked }
                }
            }
            .onReceive(session.$disliked.removeDuplicates()) { ids in
                if kind == .disliked, dislikedIDs != ids { dislikedIDs = ids }
            }
    }

    private var isArtistCollection: Bool {
        if case .artistFamiliar(_, _, false) = kind { return true }
        return false
    }

    private var downloadPanelVisibility: AnyPublisher<Bool, Never> {
        downloads.$queue.combineLatest(downloads.$failed)
            .map { !$0.0.isEmpty || !$0.1.isEmpty }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private var page: some View {
        let tracks = shown
        let rows = TrackSlots(tracks: tracks, stableIDs: kind == .likes)
        let list = ScrollViewReader { proxy in
            List {
                header(count: all.count)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
                if !reordering {
                    controlsBar
                    if !plainOrder {
                        activeFilterBar(shownCount: tracks.count, totalCount: all.count)
                    }
                }
                if kind == .downloads, hasDownloadPanel {
                    DownloadsPanel()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                } else if tracks.isEmpty {
                    empty
                }
                trackRows(rows, tracks: tracks)
                if kind == .likes, !model.tracks.isEmpty {
                    likesFooter
                }
                if let album = model.album, plainOrder, !selecting, !tracks.isEmpty {
                    albumFooter(album)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .environment(\.editMode, .constant(reordering ? .active : .inactive))
            .screenRefresh { await model.load(kind, force: true) }
            .onChange(of: model.tracks.count) { _ in
                // Снимок прокрученной страницы: по нему проверяется читаемость шапки.
                if Demo.screen == "albumscroll", rows.slots.indices.contains(7) {
                    proxy.scrollTo(rows.slots[7].id, anchor: .top)
                }
            }
        }
        return TrackListChrome(
            chrome: chrome,
            navTitle: navTitle,
            alwaysShown: false,
            searching: searching,
            title: title,
            cover: cover,
            usesTone: usesCoverTone,
            content: list
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            if searching {
                searchBar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting {
                selectionBar
            }
        }
        .sheet(isPresented: $pickingMany, onDismiss: endModes) {
            PlaylistPicker(tracks: chosen)
        }
        .onDisappear {
            // Строка поиска убирается при уходе со страницы: открытая, она при возврате
            // выскакивала рывком. Сам фильтр остаётся, строка вернётся вместе со страницей.
            searching = false
            focused = false
        }
        .onAppear {
            if !filter.isEmpty, !searching {
                withAnimation(.easeInOut(duration: 0.25)) { searching = true }
            }
            guard !prepared else { return }
            prepared = true
            if let playlist { auto = Settings.autoPlaylists.contains(playlist.id) }
            if kind == .downloads {
                downloadEntries = downloads.entries
                model.loadFilters(for: kind, sourceTracks: downloadEntries.map(\.track))
            }
            // Без сети и в офлайн-режиме сразу показано то, что можно слушать.
            if kind != .downloads, Connectivity.shared.offline || session.offline { onlyDownloaded = true }
        }
        .task { await model.load(kind) }
        .onChange(of: model.filters) { filters in
            if let selectedFilter, !filters.contains(where: { $0.id == selectedFilter }) {
                self.selectedFilter = nil
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let liked {
                    Button(action: toggleLike) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? Theme.accentText : Theme.text)
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searching = true }
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .accessibilityLabel("Поиск")
                }
            }
            toolbarGap()
            ToolbarItem(placement: .navigationBarTrailing) {
                if selecting || reordering {
                    Button("Готово", action: endModes)
                } else {
                    Menu {
                        menu
                    } label: {
                        Image(systemName: "ellipsis")
                            .accessibilityLabel("Ещё")
                    }
                }
            }
        }
        .alert("Удалить всю скачанную музыку?", isPresented: $confirmRemove) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) { downloads.removeAll() }
        }
        .alert("Удалить плейлист «\(title)»?", isPresented: $confirmDelete) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                guard let playlist else { return }
                Task {
                    if await session.delete(playlist) { dismiss() }
                }
            }
        }
        .alert("Название плейлиста", isPresented: $renaming) {
            TextField("Название", text: $name)
            Button("Сохранить") {
                guard let playlist else { return }
                let title = name
                Task {
                    if await session.rename(playlist, to: title) { model.title = title.trimmingCharacters(in: .whitespaces) }
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private struct TrackSlot: Identifiable {
        let id: String
        let index: Int
        let track: Track
    }

    @ViewBuilder
    private func trackRows(_ rows: TrackSlots, tracks: [Track]) -> some View {
        if kind == .likes {
            ForEach(rows) { row in
                listTrack(row, tracks: tracks)
            }
        } else {
            ForEach(rows) { row in
                if kind == .history, plainOrder, let day = model.days[row.track.id] {
                    Text(day)
                        .font(.scaled(size: 20, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: row.index == 0 ? 4 : 20, leading: 16, bottom: 6, trailing: 16))
                }
                if let disk = diskStart(row.index) {
                    Text("Диск \(disk)")
                        .font(.scaled(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                }
                listTrack(row, tracks: tracks).id(row.id)
            }
            .onMove(perform: reordering ? move : nil)
        }
    }

    private struct TrackSlots: RandomAccessCollection {
        let slots: [TrackSlot]

        init(tracks: [Track], stableIDs: Bool) {
            if stableIDs {
                slots = tracks.enumerated().map { TrackSlot(id: $1.id, index: $0, track: $1) }
            } else {
                var counts: [String: Int] = [:]
                slots = tracks.enumerated().map { index, track in
                    let seen = counts[track.id, default: 0]
                    counts[track.id] = seen + 1
                    let id = seen == 0 ? track.id : "\(track.id)#\(seen)"
                    return TrackSlot(id: id, index: index, track: track)
                }
            }
        }

        var startIndex: Int { slots.startIndex }
        var endIndex: Int { slots.endIndex }
        func index(after i: Int) -> Int { i + 1 }
        func index(before i: Int) -> Int { i - 1 }
        subscript(index: Int) -> TrackSlot { slots[index] }
    }

    private var usesCoverTone: Bool {
        switch kind {
        case .likes, .downloads, .history, .disliked: return false
        default: return true
        }
    }

    @ViewBuilder
    private func listTrack(_ row: TrackSlot, tracks: [Track]) -> some View {
        if selecting {
            SelectRow(track: row.track, on: selected.contains(row.track.id)) {
                if !selected.insert(row.track.id).inserted { selected.remove(row.track.id) }
            }
        } else {
            regularRow(row.track, index: row.index, tracks: tracks)
        }
    }

    private func regularRow(_ track: Track, index: Int, tracks: [Track]) -> some View {
        TrackRow(track: track, number: number(index), fadesDisliked: kind != .disliked,
                 onRemove: own ? { remove(track) } : nil, historySource: model.historySources[track.id]) {
            player.play(tracks, at: index, context: context)
        }
    }

    @ViewBuilder private var likesFooter: some View {
        if model.showsLikesProgress {
            ProgressView("Загружаем остальные треки")
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if let error = model.likesError {
            Placeholder(icon: "wifi.slash", title: "Не удалось загрузить все треки", text: error) {
                Task { await model.load(.likes, force: true) }
            }
        }
    }

    // MARK: - Выбор и перестановка

    private func endModes() {
        selecting = false
        reordering = false
        selected = []
    }

    /// Панель действий над выбранными треками.
    private var selectionBar: some View {
        let list = chosen
        return HStack(spacing: 4) {
            Button {
                selected = selected.count == shown.count ? [] : Set(shown.map(\.id))
            } label: {
                VStack(spacing: 3) {
                    Text("\(list.count)")
                        .font(.scaled(size: 17, weight: .bold))
                    Text(selected.count == shown.count ? "Снять" : "Все")
                        .font(.scaled(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            barButton("arrow.down.circle", kind == .downloads ? "Удалить" : "Скачать", symbol: kind == .downloads ? "trash" : nil) {
                if kind == .downloads {
                    list.forEach { downloads.remove($0.id) }
                } else {
                    downloads.download(list)
                    session.show("Скачиваем: \(plural(list.count, "трек", "трека", "треков"))")
                }
                endModes()
            }
            barButton("text.badge.plus", "В плейлист") {
                pickingMany = true
            }
            barButton("text.insert", "Далее") {
                list.reversed().forEach { player.playNext($0) }
                session.show("В очереди: \(plural(list.count, "трек", "трека", "треков"))")
                endModes()
            }
            if own {
                barButton("minus.circle", "Убрать") {
                    removeMany(list)
                    endModes()
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .frame(height: 58)
        .padding(.horizontal, 8)
        .background {
            Color.clear.glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .disabled(shown.isEmpty)
    }

    private func barButton(_ icon: String, _ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol ?? icon)
                    .font(.system(size: 19))
                Text(title)
                    .font(.scaled(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .disabled(selected.isEmpty)
        .opacity(selected.isEmpty ? 0.4 : 1)
    }

    private func removeMany(_ list: [Track]) {
        guard let playlist else { return }
        Task {
            for track in list {
                if await session.remove(track, from: playlist), let index = model.tracks.firstIndex(where: { $0.id == track.id }) {
                    model.tracks.remove(at: index)
                }
            }
        }
    }

    /// Перестановка в своём плейлисте: сначала на экране, потом на сервере.
    private func move(_ offsets: IndexSet, _ target: Int) {
        guard let playlist, let from = offsets.first, model.tracks.indices.contains(from) else { return }
        let track = model.tracks[from]
        model.tracks.move(fromOffsets: offsets, toOffset: target)
        guard let now = model.tracks.firstIndex(where: { $0.id == track.id }), now != from else { return }
        let before = now + 1 < model.tracks.count ? model.tracks[now + 1].id : nil
        Task {
            // Не вышло — показываем порядок, который на самом деле у Яндекса.
            if !(await session.move(track, in: playlist, before: before)) {
                await model.load(kind, force: true)
            }
        }
    }

    // MARK: - Альбом

    private var isAlbum: Bool {
        if case .album = kind { return true }
        return false
    }

    /// Номер трека на своём диске. Только в альбоме и без фильтра: иначе слева обложка.
    private func number(_ index: Int) -> Int? {
        guard isAlbum, plainOrder else { return nil }
        var rest = index
        for count in model.album?.disks ?? [] {
            if rest < count { return rest + 1 }
            rest -= count
        }
        return index + 1
    }

    /// Номер диска, если с этого трека он начинается. У альбома на одном диске заголовков нет.
    private func diskStart(_ index: Int) -> Int? {
        guard isAlbum, plainOrder, let disks = model.album?.disks, disks.count > 1 else { return nil }
        var first = 0
        for (disk, count) in disks.enumerated() {
            if index == first { return disk + 1 }
            first += count
        }
        return nil
    }

    /// Под треками: год, лейбл, длительность и другие альбомы исполнителя.
    @ViewBuilder private func albumFooter(_ album: AlbumPage) -> some View {
        let facts = [album.year.map { "\($0)" } ?? "", album.label].filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            if !facts.isEmpty {
                Text(facts)
            }
            Text("\(plural(model.tracks.count, "трек", "трека", "треков")) · \(lengthText(model.tracks))")
            if model.tracks.contains(where: \.uncensored) {
                Label("Есть треки без цензуры", systemImage: "checkmark.shield")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.dim)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
        if !album.versions.isEmpty {
            Shelf("Другие версии") {
                ForEach(album.versions) { card in
                    HomeCard(item: .album(card))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 18, leading: 0, bottom: 0, trailing: 0))
        }
        if !model.more.isEmpty {
            Shelf(album.artist.map { "Ещё от \($0.name)" } ?? "Ещё от исполнителя") {
                ForEach(model.more) { card in
                    HomeCard(item: .album(card))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 18, leading: 0, bottom: 12, trailing: 0))
        }
    }

    /// Поиск по списку открывается кнопкой: постоянная строка поиска мелькала при переходах.
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("Поиск")
                    .foregroundStyle(Theme.dim)
                TextField("Поиск в списке", text: $filter)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(Theme.text)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .accessibilityLabel("Очистить")
                            .foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .glass(in: Capsule())
            Button {
                filter = ""
                focused = false
                withAnimation(.easeInOut(duration: 0.2)) { searching = false }
            } label: {
                Text("Отмена")
                    .font(.scaled(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func setAuto(_ playlist: Playlist, _ on: Bool) {
        auto = on
        var list = Settings.autoPlaylists.filter { $0 != playlist.id }
        if on { list.append(playlist.id) }
        Settings.autoPlaylists = list
        if on {
            downloads.download(all)
            session.show("Плейлист будет скачиваться сам")
        }
    }

    /// Список треков текстом: «Исполнитель — Название», по строке на трек.
    private var exportText: String {
        let lines = all.map { $0.artists.isEmpty ? $0.fullTitle : "\($0.artists) — \($0.fullTitle)" }
        return ([title, ""] + lines).joined(separator: "\n")
    }

    @ViewBuilder private var menu: some View {
        if case .album(let id) = kind {
            Button { navigate(.replacement(ReplacementTarget(kind: .album, id: id, title: title))) } label: {
                Label("Подменить альбом", systemImage: "pencil")
            }
        }
        if kind == .likes || own {
            Button { importingAudio = true } label: {
                Label(uploadingAudio ? "Загружаем аудиофайлы" : "Загрузить свои треки", systemImage: "square.and.arrow.up")
            }
            .disabled(uploadingAudio)
        }
        if kind == .downloads {
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("Удалить всё скачанное", systemImage: "trash")
            }
        } else {
            Button {
                downloads.download(all)
            } label: {
                Label("Скачать всё", systemImage: "arrow.down.circle")
            }
        }
        if hasDownloadQueue {
            Button {
                downloads.cancelAll()
            } label: {
                Label("Отменить загрузки", systemImage: "xmark.circle")
            }
        }
        Divider()
        Button {
            selected = []
            selecting = true
        } label: {
            Label("Выбрать треки", systemImage: "checkmark.circle")
        }
        Menu {
            Picker("Сортировка", selection: $sort) {
                ForEach(sortOptions) { item in
                    Text(item.name).tag(item)
                }
            }
            .onChange(of: sortOptions) { options in
                if !options.contains(sort) { sort = .original }
            }
        } label: {
            Label("Сортировка", systemImage: "arrow.up.arrow.down")
        }
        if kind != .downloads {
            Toggle(isOn: $onlyDownloaded) {
                Label("Только скачанные", systemImage: "arrow.down.circle")
            }
        }
        if let playlist {
            Toggle(isOn: Binding(get: { auto }, set: { setAuto(playlist, $0) })) {
                Label("Скачивать автоматически", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        if let shareURL {
            ShareLink(item: shareURL) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        }
        if !all.isEmpty {
            ShareLink(item: exportText) {
                Label("Экспортировать списком", systemImage: "doc.plaintext")
            }
            let links = all.filter { !$0.isPrivate }.compactMap(\.shareURL)
            if !links.isEmpty {
                ShareLink(item: links.map(\.absoluteString).joined(separator: "\n")) {
                    Label("Экспортировать ссылки", systemImage: "link")
                }
            }
        }
        if own {
            Divider()
            Button {
                filter = ""
                sort = .original
                onlyDownloaded = false
                selectedFilter = nil
                reordering = true
            } label: {
                Label("Изменить порядок", systemImage: "line.3.horizontal")
            }
            Button {
                name = title
                renaming = true
            } label: {
                Label("Переименовать", systemImage: "pencil")
            }
            Button {
                choosingCover = true
            } label: {
                Label(uploadingCover ? "Загружается обложка" : "Сменить обложку", systemImage: "photo")
            }
            .disabled(uploadingCover)
            if let open = model.info?.open {
                Button {
                    setOpen(!open)
                } label: {
                    Label(open ? "Сделать приватным" : "Открыть доступ по ссылке", systemImage: open ? "lock" : "link")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Удалить плейлист", systemImage: "trash")
            }
        }
    }

    private func setOpen(_ open: Bool) {
        guard let playlist else { return }
        Task {
            do {
                try await API.shared.setPlaylistOpen(uid: playlist.owner, kind: playlist.kind, open)
                model.info?.open = open
                session.show(open ? "Плейлист открыт по ссылке" : "Плейлист виден только вам")
            } catch {
                session.show("Не удалось изменить доступ")
            }
        }
    }

    private func remove(_ track: Track) {
        guard let playlist else { return }
        Task {
            if await session.remove(track, from: playlist), let index = model.tracks.firstIndex(where: { $0.id == track.id }) {
                model.tracks.remove(at: index)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if model.loading {
            RowsSkeleton()
        } else if let error = model.error {
            Placeholder(icon: "wifi.slash", title: "Не удалось загрузить", text: error) {
                Task { await model.load(kind, force: true) }
            }
        } else if !filter.isEmpty {
            Placeholder(icon: "magnifyingglass", title: "Ничего не найдено")
        } else if kind == .downloads {
            Placeholder(icon: "arrow.down.circle", title: "Пока ничего не скачано", text: "Смахните трек влево или выберите «Скачать» в его меню — он будет играть без интернета.")
        } else if own {
            Placeholder(icon: "music.note.list", title: "В плейлисте пока пусто", text: "Добавляйте треки через их меню: «Добавить в плейлист».")
        } else {
            Placeholder(icon: "music.note.list", title: "Здесь пока пусто")
        }
    }

    private var isSystemList: Bool {
        switch kind {
        case .likes, .downloads, .history, .disliked: return true
        default: return false
        }
    }

    @ViewBuilder private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(sortOptions) { item in
                            Text(item.name).tag(item)
                        }
                    }
                } label: {
                    let active = sort != .original
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(active ? sort.name : "Порядок")
                            .font(.scaled(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(active ? Color.black : Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(active ? Theme.accent : Theme.raised, in: Capsule())
                }
                if kind != .downloads {
                    Button {
                        onlyDownloaded.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Скачанные")
                                .font(.scaled(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(onlyDownloaded ? Color.black : Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(onlyDownloaded ? Theme.accent : Theme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.filters) { item in
                    let on = selectedFilter == item.id
                    Button {
                        selectedFilter = on ? nil : item.id
                    } label: {
                        Text(item.name)
                            .font(.scaled(size: 13, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(on ? Theme.accent : Theme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
    }

    private func activeFilterBar(shownCount: Int, totalCount: Int) -> some View {
        let filtered = onlyDownloaded || selectedFilter != nil || !filter.isEmpty
        return HStack {
            Text(filtered ? "Показано \(shownCount) из \(totalCount)" : "Сортировка: \(sort.name)")
                .font(.scaled(size: 13))
                .foregroundStyle(Theme.dim)
            Spacer(minLength: 8)
            Button("Сбросить") {
                onlyDownloaded = false
                selectedFilter = nil
                sort = .original
                filter = ""
            }
            .font(.scaled(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder private var artwork: some View {
        switch kind {
        case .likes:
            SymbolCover(symbol: "heart.fill", colors: SymbolCover.likes, size: 82, corner: 18)
        case .downloads:
            SymbolCover(symbol: "arrow.down", colors: SymbolCover.downloads, size: 82, corner: 18)
        case .history:
            SymbolCover(symbol: "clock.arrow.circlepath", colors: SymbolCover.history, size: 82, corner: 18)
        case .disliked:
            SymbolCover(symbol: "hand.thumbsdown.fill", colors: SymbolCover.disliked, size: 82, corner: 18)
        default:
            CoverView(uri: cover, size: 168, corner: 18)
        }
    }

    /// Строка под названием: автор чужого плейлиста, число треков, длительность.
    private func summary(_ count: Int) -> String {
        let amount = plural(count, "трек", "трека", "треков")
        if kind == .downloads {
            let bytes = downloadEntries.reduce(0) { $0 + $1.bytes }
            return "\(amount) · \(Storage.sizeText(bytes))"
        }
        var parts: [String] = []
        if !own, let author = model.info?.author, !author.isEmpty { parts.append(author) }
        parts.append(amount)
        if !isAlbum { parts.append(lengthText(all)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func header(count: Int) -> some View {
        if isSystemList {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    artwork
                        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kindName.uppercased())
                            .font(.scaled(size: 11, weight: .semibold))
                            .kerning(1)
                            .foregroundStyle(Theme.text.opacity(0.6))
                        Text(title)
                            .font(.scaled(size: 24, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                            .background {
                                HeaderWatch { navTitle.setProgress($0) }
                            }
                        Text(count > 0 ? summary(count) : kindName)
                            .font(.scaled(size: 13))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                headerActions(count: count)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 6) {
                artwork
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                    .padding(.bottom, 8)
                    .photosPicker(isPresented: $choosingCover, selection: $coverPhoto, matching: .images)
                    .onChange(of: coverPhoto) { photo in
                        guard let photo else { return }
                        Task { await uploadCover(photo) }
                    }
                Text(kindName.uppercased())
                    .font(.scaled(size: 11, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Theme.text.opacity(0.6))
                Text(title)
                    .font(.scaled(size: 26, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .background {
                        HeaderWatch { navTitle.setProgress($0) }
                    }
                if !model.subtitle.isEmpty {
                    Button {
                        if let artist = model.album?.artist, !artist.id.isEmpty { navigate(.artist(artist.id, artist.name)) }
                    } label: {
                        Text(model.subtitle)
                            .font(.scaled(size: 15, weight: .medium))
                            .foregroundStyle(Theme.text.opacity(0.75))
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                }
                if count > 0 {
                    Text(summary(count))
                        .font(.scaled(size: 13))
                        .foregroundStyle(Theme.text.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                if let about = model.info?.about, !about.isEmpty {
                    Text(about)
                        .font(.scaled(size: 14))
                        .foregroundStyle(Theme.text.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.top, 4)
                }
                headerActions(count: count)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func headerActions(count: Int) -> some View {
        HStack(spacing: 14) {
            RoundButton(symbol: kind == .downloads ? "trash" : "arrow.down.to.line") {
                if kind == .downloads {
                    confirmRemove = true
                } else {
                    downloads.download(all)
                    session.show("Скачиваем: \(plural(all.count, "трек", "трека", "треков"))")
                }
            }
            PlayButton(context: context) {
                player.play(shown.isEmpty ? all : shown, context: context)
            }
            RoundButton(symbol: "shuffle") {
                player.play(shown.isEmpty ? all : shown, context: context, shuffled: true)
            }
        }
        .disabled(count == 0)
        .opacity(count == 0 ? 0.5 : 1)
    }

    private func uploadCover(_ photo: PhotosPickerItem) async {
        guard let playlist, own, !uploadingCover else { return }
        uploadingCover = true
        defer {
            uploadingCover = false
            coverPhoto = nil
        }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self),
                  let jpeg = await Task.detached(priority: .userInitiated, operation: {
                      ImageLoader.playlistCoverJPEG(data)
                  }).value else { throw TuneError("Не удалось прочитать фото") }
            model.cover = try await session.updateCover(playlist, jpeg: jpeg)
            session.show("Обложка обновлена")
        } catch {
            if !(error is CancellationError) { session.show(error.localizedDescription) }
        }
    }
}

/// Очередь загрузок на странице скачанного: что качается, что ждёт и что не вышло.
private struct DownloadsPanel: View {
    @EnvironmentObject private var downloads: Downloads

    private var status: String {
        if downloads.paused { return "На паузе" }
        if downloads.holding { return "Ждём Wi-Fi" }
        return "Скачивается"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !downloads.queue.isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status)
                            .font(.scaled(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("В очереди: \(plural(downloads.queue.count, "трек", "трека", "треков"))")
                            .font(.scaled(size: 13))
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer(minLength: 0)
                    control(downloads.paused ? "play.fill" : "pause.fill") {
                        if downloads.paused { downloads.resume() } else { downloads.pause() }
                    }
                    control("xmark") {
                        downloads.cancelAll()
                    }
                }
                .padding(.bottom, 10)
                ForEach(downloads.queue.prefix(4)) { track in
                    row(track)
                }
                if downloads.queue.count > 4 {
                    Text("и ещё \(downloads.queue.count - 4)")
                        .font(.scaled(size: 13))
                        .foregroundStyle(Theme.dim)
                        .padding(.top, 6)
                }
            }
            if !downloads.failed.isEmpty {
                if !downloads.queue.isEmpty {
                    Rectangle()
                        .fill(Theme.text.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 12)
                }
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Не удалось скачать: \(downloads.failed.count)")
                            .font(.scaled(size: 15, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(downloads.failed.prefix(2).map(\.title).joined(separator: ", "))
                            .font(.scaled(size: 13))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Повторить") {
                        downloads.retryFailed()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Theme.accent, in: Capsule())
                    control("xmark") {
                        downloads.forgetFailed()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 32, height: 32)
                .background(Theme.text.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
    }

    private func row(_ track: Track) -> some View {
        HStack(spacing: 10) {
            CoverView(uri: track.cover, size: 38, corner: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.fullTitle)
                    .font(.scaled(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(track.artists)
                    .font(.scaled(size: 13))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if downloads.isRunning(track.id) {
                ProgressRing(value: downloads.active[track.id] ?? 0)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 6)
            } else {
                Button {
                    downloads.cancel(track.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Строка в режиме выбора: вместо меню — отметка, нажатие отмечает трек.
private struct SelectRow: View {
    let track: Track
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23))
                    .foregroundStyle(on ? Theme.accentText : Theme.dim)
                CoverView(uri: track.cover, size: 50, corner: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.fullTitle)
                        .font(.scaled(size: 16, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(track.artists.isEmpty ? track.albumTitle : track.artists)
                        .font(.scaled(size: 14))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }
}

/// Страница исполнителя.
struct ArtistScreen: View {
    let id: String
    let name: String

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var session: Session
    @Environment(\.navigate) private var navigate
    @State private var page: ArtistPage?
    @State private var expanded = false
    @State private var error: String?
    @State private var tone = Theme.tone
    @State private var navTitle = NavTitleState()
    @State private var filters: [TrackFilter] = []
    @State private var selectedFilter: String? = nil
    private static var filterCache: [String: [TrackFilter]] = [:]

    var body: some View {
        List {
            if let page {
                VStack(spacing: 10) {
                    CoverView(uri: page.cover, size: 190, round: true)
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                        .padding(.bottom, 8)
                    Text("ИСПОЛНИТЕЛЬ")
                        .font(.scaled(size: 11, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(Theme.text.opacity(0.6))
                    Text(page.name)
                        .font(.scaled(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .background {
                            HeaderWatch { navTitle.setProgress($0) }
                        }
                    if let listeners = page.listeners, listeners > 0 {
                        Text("\(shortCount(listeners)) слушателей за месяц")
                            .font(.scaled(size: 14))
                            .foregroundStyle(Theme.text.opacity(0.6))
                    }
                    HStack(spacing: 14) {
                        RoundButton(symbol: session.likedArtists.contains(id) ? "heart.fill" : "heart", active: session.likedArtists.contains(id)) {
                            session.toggleArtist(id)
                        }
                        PlayButton(context: PlayContext(kind: "artist", item: id, name: page.name)) {
                            player.play(page.popular, context: PlayContext(kind: "artist", item: id, name: page.name))
                        }
                        if !TuneCatalogID.isSyntheticArtist(id) {
                            RoundButton(symbol: "dot.radiowaves.left.and.right") {
                                player.playWave(seeds: ["artist:\(id)"], name: page.name)
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))

                if let release = page.latestRelease {
                    shelf("Последний релиз", [.album(release)])
                }
                if !page.popular.isEmpty {
                    heading("Популярные треки", more: .artistTracks(id, page.name))
                    if !filters.isEmpty {
                        TrackFilterBar(filters: filters, selected: $selectedFilter)
                    }
                    let filteredPopular: [Track] = {
                        if let selectedFilter, let filter = filters.first(where: { $0.id == selectedFilter }) {
                            return page.popular.filter { filter.trackIds.contains($0.id) }
                        }
                        return Array(page.popular.prefix(5))
                    }()
                    let playSource = selectedFilter == nil ? page.popular : filteredPopular
                    ForEach(Array(filteredPopular.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track) {
                            player.play(playSource, at: index, context: PlayContext(kind: "artist", item: id, name: page.name))
                        }
                    }
                }
                if let extraTracks = page.extraTracks, !extraTracks.isEmpty {
                    heading("Добавленные треки", more: .artistTracks(id, page.name))
                    let shown = Array(extraTracks.prefix(5))
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track) {
                            player.play(extraTracks, at: index, context: PlayContext(kind: "artist", item: id, name: page.name))
                        }
                    }
                }
                Section {
                    Button { navigate(.artistFamiliar(id, page.name, false)) } label: {
                        Label("У вас в коллекции", systemImage: "heart")
                    }
                    Button { navigate(.artistFamiliar(id, page.name, true)) } label: {
                        Label("Слушали в Волне", systemImage: "waveform")
                    }
                }
                .foregroundStyle(Theme.text)
                .listRowBackground(Color.clear)
                if !page.albums.isEmpty {
                    shelf("Альбомы", page.albums.map { .album($0) })
                }
                if !page.singles.isEmpty {
                    shelf("Синглы и EP", page.singles.map { .album($0) })
                }
                if !page.also.isEmpty {
                    shelf("Сборники и участие", page.also.map { .album($0) })
                }
                if !page.playlists.isEmpty {
                    shelf("Плейлисты", page.playlists.map { .playlist($0) })
                }
                ArtistExtras(clips: page.clips ?? [], concerts: page.concerts ?? [])
                if !page.similar.isEmpty {
                    shelf("Похожие исполнители", page.similar.map { .artist($0) })
                }
                if !page.about.isEmpty {
                    about(page.about)
                }
            } else if let error {
                Placeholder(icon: "wifi.slash", title: "Не удалось загрузить", text: error) {
                    Task { await load() }
                }
            } else {
                RowsSkeleton(count: 9)
                    .padding(.top, 12)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.background
                LinearGradient(colors: [Theme.wash(tone), Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 440)
            }
            .ignoresSafeArea()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                NavBarTitle(state: navTitle, alwaysShown: false, hidden: false, title: page?.name ?? name)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        navigate(.replacement(ReplacementTarget(kind: .artist, id: id, title: page?.name ?? name)))
                    } label: {
                        Label("Подменить исполнителя", systemImage: "pencil")
                    }
                    if !TuneCatalogID.isSyntheticArtist(id), let url = URL(string: "https://music.yandex.ru/artist/\(id)") {
                        ShareLink(item: url) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis").accessibilityLabel("Ещё")
                }
            }
        }
        .task { if page == nil { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: MetadataOverrides.changed)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Uncensor.changed)) { _ in
            Task { await load() }
        }
        .task(id: page?.cover) {
            let color = await ImageLoader.shared.tone(page?.cover)
            withAnimation(.easeInOut(duration: 0.3)) { tone = color ?? Theme.tone }
        }
        .task(id: page?.popular.map(\.id)) {
            await loadFilters()
        }
    }

    /// «Об исполнителе»: три строки, по нажатию — целиком.
    private func about(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Об исполнителе")
                .font(.scaled(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(text)
                .font(.scaled(size: 15))
                .foregroundStyle(Theme.text.opacity(0.75))
                .lineLimit(expanded ? nil : 3)
            if !expanded {
                Text("Читать дальше")
                    .font(.scaled(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 16, trailing: 16))
    }

    private func shelf(_ title: String, _ items: [HomeItem]) -> some View {
        Shelf(title) {
            ForEach(items) { item in
                HomeCard(item: item)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 12, trailing: 0))
    }

    private func heading(_ text: String, more: Route) -> some View {
        HStack {
            Text(text)
                .font(.scaled(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                navigate(more)
            } label: {
                Text("Все")
                    .font(.scaled(size: 15, weight: .medium))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
    }

    private func load() async {
        error = nil
        let file = "Lists/" + Storage.hash("artist:" + id) + ".json"
        if page == nil, !Demo.on {
            _ = Storage.lists
            let saved = await Task.detached(priority: .userInitiated) { Storage.load(file, as: ArtistPage.self) }.value
            if page == nil { page = saved }
        }
        do {
            let fresh = try await API.shared.artist(id: id, includeExtras: true)
            page = fresh
            if !Demo.on {
                Task.detached(priority: .utility) { Storage.save(fresh, file) }
            }
        } catch {
            if Task.isCancelled { return }
            // Сохранённая страница остаётся на экране, даже если обновить её не вышло.
            if page == nil {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadFilters() async {
        guard let popular = page?.popular else {
            filters = []
            selectedFilter = nil
            return
        }
        var seen = Set<String>()
        let ids = popular.map(\.id).filter {
            !$0.isEmpty && $0.allSatisfy(\.isNumber) && !TuneCatalogID.isSyntheticTrack($0) && seen.insert($0).inserted
        }
        guard ids.count >= 4 else {
            filters = []
            selectedFilter = nil
            return
        }
        let cacheKey = "artist:\(id):\(ids.count):\(ids.first ?? ""):\(ids.last ?? "")"
        if let cached = Self.filterCache[cacheKey] {
            filters = cached
            if let selectedFilter, !cached.contains(where: { $0.id == selectedFilter }) {
                self.selectedFilter = nil
            }
            return
        }
        guard !Connectivity.shared.offline, !Session.shared.offline else { return }
        guard let loaded = try? await API.shared.trackFilters(ids: ids), !Task.isCancelled else { return }
        Self.filterCache[cacheKey] = loaded
        filters = loaded
        if let selectedFilter, !loaded.contains(where: { $0.id == selectedFilter }) {
            self.selectedFilter = nil
        }
    }
}
