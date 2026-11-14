import SwiftUI

enum ListKind: Hashable {
    case likes
    case downloads
    case history
    case disliked
    case playlist(Playlist)
    case album(String)
    case artist(String, String)
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
    private var loaded = false

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
        case .artist(let id, _): key = "artist:" + id
        case .history: key = "history"
        default: return nil
        }
        _ = Storage.lists
        return "Lists/" + Storage.hash(key) + ".json"
    }

    func load(_ kind: ListKind, force: Bool = false) async {
        if loaded && !force { return }
        loading = tracks.isEmpty
        error = nil
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
                loading = false
            }
        }
        defer { loading = false }
        do {
            switch kind {
            case .downloads:
                break
            case .likes:
                try await loadLikes()
            case .history:
                let page = try await API.shared.history()
                tracks = page.tracks
                days = page.days
                historySources = page.sources
            case .disliked:
                if Session.shared.profile == nil { await Session.shared.refresh() }
                var found: [Track] = []
                for chunk in Array(Session.shared.disliked).chunked(150) {
                    found += try await API.shared.tracks(ids: chunk)
                }
                tracks = found
            case .playlist(let playlist):
                if title.isEmpty { title = playlist.title }
                cover = playlist.cover
                let page = try await API.shared.playlist(playlist)
                tracks = page.tracks
                info = page
                if title.isEmpty { title = page.title }
                if cover == nil { cover = page.cover }
            case .album(let id):
                let page = try await API.shared.album(id: id)
                title = page.card.title
                subtitle = page.card.subtitle
                cover = page.card.cover
                tracks = page.tracks
                album = page
                if more.isEmpty, let artist = page.artist, !artist.id.isEmpty {
                    Task { [weak self] in
                        guard let info = try? await API.shared.artist(id: artist.id) else { return }
                        self?.more = (info.albums + info.singles).filter { $0.id != id }
                    }
                }
            case .artist(let id, let name):
                title = name
                tracks = try await API.shared.artistTracks(id: id)
            }
            loaded = true
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
    private func loadLikes() async throws {
        if tracks.isEmpty, !Demo.on {
            let cached = await Task.detached(priority: .userInitiated) { Storage.load("likes-tracks.json", as: [Track].self) }.value
            if let cached, tracks.isEmpty {
                tracks = cached
                loading = false
            }
        }
        if Session.shared.profile == nil {
            await Session.shared.refresh()
        }
        guard let uid = Session.shared.profile?.uid else { throw APIError.network("") }
        let entries = try await API.shared.likedEntries(uid: uid)
        let ids = entries.map(\.id)
        Session.shared.setLiked(ids)
        var known: [String: Track] = [:]
        for track in tracks { known[track.id] = track }
        let missing = ids.filter { known[$0] == nil }
        func orderedTracks() -> [Track] {
            entries.compactMap { entry in
                guard var track = known[entry.id] else { return nil }
                track.addedAt = entry.addedAt ?? track.addedAt
                return track
            }
        }
        for chunk in missing.chunked(150) {
            for track in try await API.shared.tracks(ids: chunk) { known[track.id] = track }
            tracks = orderedTracks()
        }
        let ordered = orderedTracks()
        if ordered != tracks { tracks = ordered }
        Downloads.shared.auto(ordered)
        if !Demo.on {
            Task.detached(priority: .utility) { Storage.save(ordered, "likes-tracks.json") }
        }
    }
}

/// Страница плейлиста, альбома, лайков, истории или скачанного: шапка с обложкой и список треков.
struct TrackListScreen: View {
    let kind: ListKind

    @StateObject private var model = TrackListModel()
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigate) private var navigate
    @State private var filter = ""
    @State private var searching = Demo.screen == "filter"
    @FocusState private var focused: Bool
    @State private var confirmRemove = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var name = ""
    @State private var tone = Theme.tone
    @State private var sort = TrackSort.original
    @State private var onlyDownloaded = false
    /// Режим выбора нескольких треков.
    @State private var selecting = Demo.screen == "select"
    @State private var selected = Set<String>()
    /// Режим перестановки треков в своём плейлисте.
    @State private var reordering = false
    @State private var pickingMany = false
    /// Шапка ушла за край: название страницы показывается в панели навигации.
    @State private var compact = false
    /// Плейлист скачивается сам.
    @State private var auto = false
    @State private var prepared = false

    private var all: [Track] {
        switch kind {
        case .downloads: return downloads.tracks
        // Трек пропадает из списка, как только с него сняли дизлайк.
        case .disliked: return model.tracks.filter { session.disliked.contains($0.id) }
        default: return model.tracks
        }
    }

    private var shown: [Track] {
        var list = all
        if onlyDownloaded { list = list.filter { downloads.has($0.id) } }
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
                for entry in downloads.entries { downloadDates[entry.track.id] = entry.date }
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
        filter.isEmpty && sort == .original && !onlyDownloaded
    }

    private var chosen: [Track] {
        shown.filter { selected.contains($0.id) }
    }

    private var playlist: Playlist? {
        if case .playlist(let playlist) = kind { return playlist }
        return nil
    }

    private var own: Bool {
        playlist.map(session.isOwn) ?? false
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
        case .album(let id): return URL(string: "https://music.yandex.ru/album/\(id)")
        case .playlist(let playlist): return playlist.shareURL
        default: return nil
        }
    }

    /// Сердечко есть у альбома и чужого плейлиста: оно добавляет их в коллекцию.
    private var liked: Bool? {
        switch kind {
        case .album(let id): return session.likedAlbums.contains(id)
        case .playlist(let playlist): return own ? nil : session.isLiked(playlist)
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
        let tracks = shown
        ScrollViewReader { proxy in
            List {
                header(count: all.count)
                    // Шапка почти ушла под панель навигации: пора показать название в панели.
                    .background { HeaderWatch(hidden: $compact) }
                    .onDisappear { compact = true }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                if kind == .downloads, !downloads.queue.isEmpty || !downloads.failed.isEmpty {
                    DownloadsPanel()
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                } else if tracks.isEmpty {
                    empty
                }
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    if kind == .history, plainOrder, let day = model.days[track.id] {
                        Text(day)
                            .font(.scaled(size: 20, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: index == 0 ? 4 : 20, leading: 16, bottom: 6, trailing: 16))
                    }
                    if let disk = diskStart(index) {
                        Text("Диск \(disk)")
                            .font(.scaled(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }
                    Group {
                        if selecting {
                            SelectRow(track: track, on: selected.contains(track.id)) {
                                if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
                            }
                        } else {
                            regularRow(track, index: index, tracks: tracks)
                        }
                    }
                    .id(index)
                }
                .onMove(perform: reordering ? move : nil)
                if let album = model.album, plainOrder, !selecting, !tracks.isEmpty {
                    albumFooter(album)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .environment(\.editMode, .constant(reordering ? .active : .inactive))
            .onChange(of: model.tracks.count) { _ in
                // Снимок прокрученной страницы: по нему проверяется читаемость шапки.
                if Demo.screen == "albumscroll" { proxy.scrollTo(7, anchor: .top) }
            }
        }
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.background
                LinearGradient(colors: [Theme.wash(tone), Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 460)
            }
            .ignoresSafeArea()
        }
        .topScrim(Theme.wash(tone))
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
        .navigationTitle(compact && !searching ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .background(BarFade(title: compact && !searching ? title : ""))
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
            // Без сети и в офлайн-режиме сразу показано то, что можно слушать.
            if kind != .downloads, Settings.offlineMode || session.offline { onlyDownloaded = true }
        }
        .task { await model.load(kind) }
        .task(id: cover) {
            switch kind {
            case .disliked, .likes, .downloads, .history: tone = Theme.tone
            default:
                let color = await ImageLoader.shared.tone(cover)
                withAnimation(.easeInOut(duration: 0.3)) { tone = color ?? Theme.tone }
            }
        }
        .refreshable { await model.load(kind, force: true) }
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

    private func regularRow(_ track: Track, index: Int, tracks: [Track]) -> some View {
        TrackRow(track: track, number: number(index), fadesDisliked: kind != .disliked,
                 onRemove: own ? { remove(track) } : nil, historySource: model.historySources[track.id]) {
            player.play(tracks, at: index, context: context)
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
        if !downloads.queue.isEmpty {
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
        }
        if own {
            Divider()
            Button {
                filter = ""
                sort = .original
                onlyDownloaded = false
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

    @ViewBuilder private var artwork: some View {
        switch kind {
        case .likes:
            SymbolCover(symbol: "heart.fill", colors: SymbolCover.likes, size: 200, corner: 22)
        case .downloads:
            SymbolCover(symbol: "arrow.down", colors: SymbolCover.downloads, size: 200, corner: 22)
        case .history:
            SymbolCover(symbol: "clock.arrow.circlepath", colors: SymbolCover.history, size: 200, corner: 22)
        case .disliked:
            SymbolCover(symbol: "hand.thumbsdown.fill", colors: SymbolCover.disliked, size: 200, corner: 22)
        default:
            CoverView(uri: cover, size: 220, corner: 18)
        }
    }

    /// Строка под названием: автор чужого плейлиста, число треков, длительность.
    private func summary(_ count: Int) -> String {
        let amount = plural(count, "трек", "трека", "треков")
        if kind == .downloads { return "\(amount) · \(Storage.sizeText(downloads.totalBytes))" }
        var parts: [String] = []
        if !own, let author = model.info?.author, !author.isEmpty { parts.append(author) }
        parts.append(amount)
        if !isAlbum { parts.append(lengthText(all)) }
        return parts.joined(separator: " · ")
    }

    private func header(count: Int) -> some View {
        VStack(spacing: 6) {
            artwork
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                .padding(.bottom, 12)
            Text(kindName.uppercased())
                .font(.scaled(size: 11, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.text.opacity(0.6))
            Text(title)
                .font(.scaled(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(3)
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
                    player.play(all, context: context)
                }
                RoundButton(symbol: "shuffle") {
                    player.play(all, context: context, shuffled: true)
                }
            }
            .padding(.top, 14)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity)
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
    @State private var compact = false

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
                        RoundButton(symbol: "dot.radiowaves.left.and.right") {
                            player.playWave(seeds: ["artist:\(id)"], name: page.name)
                        }
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                .background { HeaderWatch(hidden: $compact) }
                .onDisappear { compact = true }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))

                if let release = page.latestRelease {
                    shelf("Последний релиз", [.album(release)])
                }
                if !page.popular.isEmpty {
                    heading("Популярные треки", more: .artistTracks(id, page.name))
                    let top = Array(page.popular.prefix(5))
                    ForEach(Array(top.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track) {
                            player.play(page.popular, at: index, context: PlayContext(kind: "artist", item: id, name: page.name))
                        }
                    }
                }
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
        .topScrim(Theme.wash(tone))
        .navigationTitle(compact ? (page?.name ?? name) : "")
        .navigationBarTitleDisplayMode(.inline)
        .background(BarFade(title: compact ? (page?.name ?? name) : ""))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let url = URL(string: "https://music.yandex.ru/artist/\(id)") {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel("Поделиться")
                    }
                }
            }
        }
        .task { if page == nil { await load() } }
        .task(id: page?.cover) {
            let color = await ImageLoader.shared.tone(page?.cover)
            withAnimation(.easeInOut(duration: 0.3)) { tone = color ?? Theme.tone }
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
            let fresh = try await API.shared.artist(id: id)
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
}
