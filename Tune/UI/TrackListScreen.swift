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
                title = "Скачанное"
            case .likes:
                title = "Мне нравится"
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
        if tracks.isEmpty {
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
        Task.detached(priority: .utility) { Storage.save(ordered, "likes-tracks.json") }
    }
}

struct TrackListScreen: View {
    let kind: ListKind

    @StateObject private var model = TrackListModel()
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @State private var filter = ""
    @State private var confirmRemove = false

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
        case .downloads: return .various("Скачанное")
        case .playlist(let playlist): return PlayContext(kind: "playlist", item: playlist.id, name: playlist.title)
        case .album(let id): return PlayContext(kind: "album", item: id, name: model.title)
        case .artist(let id, let name): return PlayContext(kind: "artist", item: id, name: name)
        }
    }

    private var title: String {
        switch kind {
        case .likes: return "Мне нравится"
        case .downloads: return "Скачанное"
        default: return model.title
        }
    }

    var body: some View {
        let tracks = shown
        List {
            header(count: all.count)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            if tracks.isEmpty {
                empty
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                TrackRow(track: track) {
                    player.play(tracks, at: index, context: context)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Поиск в списке")
        .task { await model.load(kind) }
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
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Удалить всю скачанную музыку?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { downloads.removeAll() }
        }
    }

    @ViewBuilder private var empty: some View {
        if model.loading {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 40)
        } else if let error = model.error {
            Placeholder(icon: "wifi.slash", title: "Не удалось загрузить", text: error) {
                Task { await model.load(kind, force: true) }
            }
        } else if kind == .downloads {
            Placeholder(icon: "arrow.down.circle", title: "Пока ничего не скачано", text: "Смахните трек влево или выберите «Скачать» в его меню — он будет играть без интернета.")
        } else if !filter.isEmpty {
            Placeholder(icon: "magnifyingglass", title: "Ничего не найдено")
        } else {
            Placeholder(icon: "music.note.list", title: "Здесь пока пусто")
        }
    }

    private func header(count: Int) -> some View {
        VStack(spacing: 12) {
            if model.cover != nil {
                CoverView(uri: model.cover, size: 180, corner: 12)
            }
            if !model.subtitle.isEmpty {
                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if count > 0 {
                Text(kind == .downloads ? "\(plural(count, "трек", "трека", "треков")) · \(Storage.sizeText(downloads.totalBytes))" : plural(count, "трек", "трека", "треков"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    player.play(all, context: context)
                } label: {
                    Label("Слушать", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    player.play(all, context: context, shuffled: true)
                } label: {
                    Label("Вперемешку", systemImage: "shuffle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .disabled(count == 0)
        }
        .frame(maxWidth: .infinity)
    }
}
