import SwiftUI

enum ListKind: Hashable {
    case likes
    case downloads
    case history
    case playlist(Playlist)
    case album(String)
    case artist(String, String)
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
    private var loaded = false

    func load(_ kind: ListKind, force: Bool = false) async {
        if loaded && !force { return }
        loading = tracks.isEmpty
        error = nil
        defer { loading = false }
        do {
            switch kind {
            case .downloads:
                break
            case .likes:
                try await loadLikes()
            case .history:
                tracks = try await API.shared.history()
            case .playlist(let playlist):
                if title.isEmpty { title = playlist.title }
                cover = playlist.cover
                tracks = try await API.shared.playlistTracks(playlist)
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
        let ids = try await API.shared.likedIds(uid: uid)
        Session.shared.setLiked(ids)
        var known: [String: Track] = [:]
        for track in tracks { known[track.id] = track }
        let missing = ids.filter { known[$0] == nil }
        for chunk in missing.chunked(150) {
            for track in try await API.shared.tracks(ids: chunk) { known[track.id] = track }
            tracks = ids.compactMap { known[$0] }
        }
        let ordered = ids.compactMap { known[$0] }
        if ordered != tracks { tracks = ordered }
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

    private var all: [Track] {
        kind == .downloads ? downloads.tracks : model.tracks
    }

    private var shown: [Track] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.artists.localizedCaseInsensitiveContains(text) }
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
                if tracks.isEmpty {
                    empty
                }
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    if let disk = diskStart(index) {
                        Text("Диск \(disk)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 4, trailing: 16))
                    }
                    TrackRow(track: track, number: number(index), onRemove: own ? { remove(track) } : nil) {
                        player.play(tracks, at: index, context: context)
                    }
                    .id(index)
                }
                if let album = model.album, filter.isEmpty, !tracks.isEmpty {
                    albumFooter(album)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: model.tracks.count) { _ in
                // Снимок прокрученной страницы: по нему проверяется читаемость шапки.
                if Demo.screen == "albumscroll" { proxy.scrollTo(7, anchor: .top) }
            }
        }
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.background
                LinearGradient(colors: [tone, Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 460)
            }
            .ignoresSafeArea()
        }
        .topScrim(tone)
        .safeAreaInset(edge: .top, spacing: 0) {
            if searching {
                searchBar
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(kind) }
        .task(id: cover) {
            switch kind {
            case .likes: tone = Color(red: 0.42, green: 0.16, blue: 0.5)
            case .downloads: tone = Color(red: 0.1, green: 0.25, blue: 0.52)
            case .history: tone = Color(red: 0.08, green: 0.36, blue: 0.34)
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
                            .foregroundStyle(liked ? Theme.accent : Color.white)
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { searching = true }
                    focused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            toolbarGap()
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis")
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

    // MARK: - Альбом

    private var isAlbum: Bool {
        if case .album = kind { return true }
        return false
    }

    /// Номер трека на своём диске. Только в альбоме и без фильтра: иначе слева обложка.
    private func number(_ index: Int) -> Int? {
        guard isAlbum, filter.isEmpty else { return nil }
        var rest = index
        for count in model.album?.disks ?? [] {
            if rest < count { return rest + 1 }
            rest -= count
        }
        return index + 1
    }

    /// Номер диска, если с этого трека он начинается. У альбома на одном диске заголовков нет.
    private func diskStart(_ index: Int) -> Int? {
        guard isAlbum, filter.isEmpty, let disks = model.album?.disks, disks.count > 1 else { return nil }
        var first = 0
        for (disk, count) in disks.enumerated() {
            if index == first { return disk + 1 }
            first += count
        }
        return nil
    }

    /// Под треками: год, лейбл, длительность и другие альбомы исполнителя.
    @ViewBuilder private func albumFooter(_ album: AlbumPage) -> some View {
        let minutes = Int(model.tracks.reduce(0) { $0 + $1.duration } / 60)
        let facts = [album.year.map { "\($0)" } ?? "", album.label].filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 4) {
            if !facts.isEmpty {
                Text(facts)
            }
            Text("\(plural(model.tracks.count, "трек", "трека", "треков")) · \(minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин")")
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.dim)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
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
                    .foregroundStyle(Theme.dim)
                TextField("Поиск в списке", text: $filter)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .foregroundStyle(.white)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
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
        if !downloads.active.isEmpty {
            Button {
                downloads.cancelAll()
            } label: {
                Label("Остановить загрузки", systemImage: "xmark.circle")
            }
        }
        if let shareURL {
            ShareLink(item: shareURL) {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        }
        if own {
            Divider()
            Button {
                name = title
                renaming = true
            } label: {
                Label("Переименовать", systemImage: "pencil")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Удалить плейлист", systemImage: "trash")
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
            Spinner()
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
        default:
            CoverView(uri: cover, size: 220, corner: 18)
        }
    }

    private func header(count: Int) -> some View {
        VStack(spacing: 6) {
            artwork
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                .padding(.bottom, 12)
            Text(kindName.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(1)
                .foregroundStyle(.white.opacity(0.6))
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if !model.subtitle.isEmpty {
                Button {
                    if let artist = model.album?.artist, !artist.id.isEmpty { navigate(.artist(artist.id, artist.name)) }
                } label: {
                    Text(model.subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
            }
            if count > 0 {
                Text(kind == .downloads ? "\(plural(count, "трек", "трека", "треков")) · \(Storage.sizeText(downloads.totalBytes))" : plural(count, "трек", "трека", "треков"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
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
                PlayButton {
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

    var body: some View {
        List {
            if let page {
                VStack(spacing: 10) {
                    CoverView(uri: page.cover, size: 190, round: true)
                        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
                        .padding(.bottom, 8)
                    Text("ИСПОЛНИТЕЛЬ")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(page.name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if let listeners = page.listeners, listeners > 0 {
                        Text("\(shortCount(listeners)) слушателей за месяц")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    HStack(spacing: 14) {
                        RoundButton(symbol: session.likedArtists.contains(id) ? "heart.fill" : "heart", active: session.likedArtists.contains(id)) {
                            session.toggleArtist(id)
                        }
                        PlayButton {
                            player.play(page.popular, context: PlayContext(kind: "artist", item: id, name: page.name))
                        }
                        RoundButton(symbol: "dot.radiowaves.left.and.right") {
                            player.playWave(seeds: ["artist:\(id)"], name: page.name)
                        }
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))

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
                Spinner()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.background
                LinearGradient(colors: [tone, Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 440)
            }
            .ignoresSafeArea()
        }
        .topScrim(tone)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let url = URL(string: "https://music.yandex.ru/artist/\(id)") {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
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
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(expanded ? nil : 3)
            if !expanded {
                Text("Читать дальше")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
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
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                navigate(more)
            } label: {
                Text("Все")
                    .font(.system(size: 15, weight: .medium))
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
        do {
            page = try await API.shared.artist(id: id)
        } catch {
            if Task.isCancelled { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
