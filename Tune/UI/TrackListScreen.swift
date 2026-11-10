import SwiftUI

enum ListKind: Hashable {
    case likes
    case downloads
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
            case .playlist(let playlist):
                title = playlist.title
                cover = playlist.cover
                tracks = try await API.shared.playlistTracks(playlist)
            case .album(let id):
                let page = try await API.shared.album(id: id)
                title = page.card.title
                subtitle = page.card.subtitle
                cover = page.card.cover
                tracks = page.tracks
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

/// Страница плейлиста, альбома, лайков или скачанного: шапка с обложкой и список треков.
struct TrackListScreen: View {
    let kind: ListKind

    @StateObject private var model = TrackListModel()
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @State private var filter = ""
    @State private var confirmRemove = false
    @State private var tone = Theme.tone

    private var all: [Track] {
        kind == .downloads ? downloads.tracks : model.tracks
    }

    private var shown: [Track] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.artists.localizedCaseInsensitiveContains(text) }
    }

    private var context: PlayContext {
        switch kind {
        case .likes: return .various("Мне нравится")
        case .downloads: return .various("Скачанные треки")
        case .playlist(let playlist): return PlayContext(kind: "playlist", item: playlist.id, name: playlist.title)
        case .album(let id): return PlayContext(kind: "album", item: id, name: model.title)
        case .artist(let id, let name): return PlayContext(kind: "artist", item: id, name: name)
        }
    }

    private var title: String {
        switch kind {
        case .likes: return "Мне нравится"
        case .downloads: return "Скачанные треки"
        case .playlist(let playlist): return model.title.isEmpty ? playlist.title : model.title
        case .artist(_, let name): return name
        case .album: return model.title
        }
    }

    private var kindName: String {
        switch kind {
        case .album: return "Альбом"
        case .artist: return "Все треки"
        default: return "Плейлист"
        }
    }

    private var cover: String? {
        if case .playlist(let playlist) = kind { return model.cover ?? playlist.cover }
        return model.cover
    }

    var body: some View {
        let tracks = shown
        List {
            header(count: all.count)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
            if tracks.isEmpty {
                empty
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                TrackRow(track: track) {
                    player.play(tracks, at: index, context: context)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                Theme.background
                LinearGradient(colors: [tone, Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 460)
            }
            .ignoresSafeArea()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Поиск в списке")
        .task { await model.load(kind) }
        .task(id: cover) {
            switch kind {
            case .likes: tone = Color(red: 0.42, green: 0.16, blue: 0.5)
            case .downloads: tone = Color(red: 0.1, green: 0.25, blue: 0.52)
            default:
                let color = await ImageLoader.shared.tone(cover)
                withAnimation(.easeInOut(duration: 0.3)) { tone = color ?? Theme.tone }
            }
        }
        .refreshable { await model.load(kind, force: true) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
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
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .confirmationDialog("Удалить всю скачанную музыку?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { downloads.removeAll() }
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
        } else {
            Placeholder(icon: "music.note.list", title: "Здесь пока пусто")
        }
    }

    @ViewBuilder private var artwork: some View {
        switch kind {
        case .likes:
            SymbolCover(symbol: "heart.fill", colors: SymbolCover.likes, size: 200, corner: 18)
        case .downloads:
            SymbolCover(symbol: "arrow.down", colors: SymbolCover.downloads, size: 200, corner: 18)
        default:
            CoverView(uri: cover, size: 220, corner: 14)
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
                Text(model.subtitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
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
                    }
                }
                Button {
                    player.play(all, context: context)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Слушать")
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
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
    @Environment(\.navigate) private var navigate
    @State private var page: ArtistPage?
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
                    HStack(spacing: 14) {
                        Button {
                            player.play(page.popular, context: PlayContext(kind: "artist", item: id, name: page.name))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("Слушать")
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.accentColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
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
                    Shelf("Альбомы") {
                        ForEach(page.albums) { card in
                            HomeCard(item: .album(card))
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 12, trailing: 0))
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
        .task(id: page?.cover) {
            let color = await ImageLoader.shared.tone(page?.cover)
            withAnimation(.easeInOut(duration: 0.3)) { tone = color ?? Theme.tone }
        }
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
