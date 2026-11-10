import SwiftUI

// MARK: - Главная

struct HomeScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.navigate) private var navigate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if session.offline {
                    Label("Нет сети — доступна скачанная музыка", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                wave
                HStack(spacing: 12) {
                    tile("Мне нравится", plural(session.likedIds.count, "трек", "трека", "треков"), "heart.fill", .likes)
                    tile("Скачанное", plural(downloads.entries.count, "трек", "трека", "треков"), "arrow.down.circle.fill", .downloads)
                }
                if !session.playlists.isEmpty {
                    VStack(spacing: 12) {
                        SectionTitle("Плейлисты")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(session.playlists) { playlist in
                                    Button {
                                        navigate(.playlist(playlist))
                                    } label: {
                                        CardView(title: playlist.title, subtitle: plural(playlist.count, "трек", "трека", "треков"), cover: playlist.cover)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Главная")
        .refreshable { await session.refresh() }
    }

    private var wave: some View {
        let active = player.isWave
        return Button {
            if active {
                player.toggle()
            } else {
                player.playWave()
            }
        } label: {
            VStack(spacing: 14) {
                Image(systemName: active && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                Text("Моя волна")
                    .font(.title2.bold())
                Text("Бесконечный поток под ваш вкус")
                    .font(.subheadline)
                    .opacity(0.7)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .background(
                LinearGradient(colors: [Color.accentColor, Color(red: 0.98, green: 0.55, blue: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func tile(_ title: String, _ subtitle: String, _ icon: String, _ route: Route) -> some View {
        Button {
            navigate(route)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Поиск

struct SearchScreen: View {
    @EnvironmentObject private var player: Player
    @Environment(\.navigate) private var navigate
    @State private var query = ""
    @State private var result = SearchResult()
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Placeholder(icon: "magnifyingglass", title: "Поиск", text: "Треки, альбомы, исполнители и плейлисты")
                    .listRowSeparator(.hidden)
            } else if failed && result.isEmpty {
                Placeholder(icon: "wifi.slash", title: "Не удалось выполнить поиск")
                    .listRowSeparator(.hidden)
            } else if result.isEmpty {
                Group {
                    if loading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.vertical, 40)
                    } else {
                        Placeholder(icon: "magnifyingglass", title: "Ничего не найдено")
                    }
                }
                .listRowSeparator(.hidden)
            } else {
                if !result.artists.isEmpty {
                    shelf("Исполнители") {
                        ForEach(result.artists) { card in
                            Button {
                                navigate(.artist(card.id, card.title))
                            } label: {
                                CardView(title: card.title, subtitle: "", cover: card.cover, round: true, size: 110)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !result.albums.isEmpty {
                    shelf("Альбомы") {
                        ForEach(result.albums) { card in
                            Button {
                                navigate(.album(card.id))
                            } label: {
                                CardView(title: card.title, subtitle: card.subtitle, cover: card.cover, size: 130)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !result.tracks.isEmpty {
                    Section {
                        ForEach(Array(result.tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track) {
                                player.play(result.tracks, at: index, context: .various("Поиск"))
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
                        }
                    } header: {
                        Text("Треки")
                    }
                }
                if !result.playlists.isEmpty {
                    shelf("Плейлисты") {
                        ForEach(result.playlists) { playlist in
                            Button {
                                navigate(.playlist(playlist))
                            } label: {
                                CardView(title: playlist.title, subtitle: plural(playlist.count, "трек", "трека", "треков"), cover: playlist.cover, size: 130)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Поиск")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Трек, альбом, исполнитель")
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.immediately)
        .task(id: query) { await search() }
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 16)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
        } header: {
            Text(title)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            result = SearchResult()
            loading = false
            return
        }
        // Запрос уходит, когда пользователь перестал печатать.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        loading = true
        do {
            let found = try await API.shared.search(text)
            if Task.isCancelled { return }
            result = found
            failed = false
        } catch {
            if Task.isCancelled { return }
            failed = true
        }
        loading = false
    }
}

// MARK: - Коллекция

struct LibraryScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.likes) {
                    row("heart.fill", "Мне нравится", plural(session.likedIds.count, "трек", "трека", "треков"))
                }
                NavigationLink(value: Route.downloads) {
                    row("arrow.down.circle.fill", "Скачанное", downloads.entries.isEmpty ? "Пусто" : "\(plural(downloads.entries.count, "трек", "трека", "треков")) · \(Storage.sizeText(downloads.totalBytes))")
                }
            }
            if !session.playlists.isEmpty {
                Section("Плейлисты") {
                    ForEach(session.playlists) { playlist in
                        NavigationLink(value: Route.playlist(playlist)) {
                            HStack(spacing: 12) {
                                CoverView(uri: playlist.cover, size: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(playlist.title)
                                        .lineLimit(1)
                                    Text(plural(playlist.count, "трек", "трека", "треков"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Коллекция")
        .refreshable { await session.refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Исполнитель

struct ArtistScreen: View {
    let id: String
    let name: String

    @EnvironmentObject private var player: Player
    @Environment(\.navigate) private var navigate
    @State private var page: ArtistPage?
    @State private var error: String?

    var body: some View {
        List {
            if let page {
                VStack(spacing: 14) {
                    CoverView(uri: page.cover, size: 170, round: true)
                    Text(page.name)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Button {
                        player.playWave(seeds: ["artist:\(id)"], name: page.name)
                    } label: {
                        Label("Волна по исполнителю", systemImage: "dot.radiowaves.left.and.right")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)

                if !page.popular.isEmpty {
                    Section {
                        let top = Array(page.popular.prefix(10))
                        ForEach(Array(top.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track) {
                                player.play(page.popular, at: index, context: PlayContext(kind: "artist", item: id, name: page.name))
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 8))
                        }
                        NavigationLink(value: Route.artistTracks(id, page.name)) {
                            Text("Все треки")
                        }
                    } header: {
                        Text("Популярное")
                    }
                }
                if !page.albums.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(page.albums) { card in
                                    Button {
                                        navigate(.album(card.id))
                                    } label: {
                                        CardView(title: card.title, subtitle: card.subtitle, cover: card.cover, size: 130)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                    } header: {
                        Text("Альбомы")
                    }
                }
            } else if let error {
                Placeholder(icon: "wifi.slash", title: "Не удалось загрузить", text: error) {
                    Task { await load() }
                }
                .listRowSeparator(.hidden)
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 60)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
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

// MARK: - Настройки

struct SettingsScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @State private var uncensor = Settings.uncensor
    @State private var streamQuality = Settings.streamQuality
    @State private var downloadQuality = Settings.downloadQuality
    @State private var cacheBytes: Int64 = 0
    @State private var confirmLogout = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section("Аккаунт") {
                LabeledContent("Имя", value: session.profile?.name ?? "—")
                LabeledContent("Плюс", value: session.profile?.plus == true ? "Активен" : "Нет")
            }
            Section {
                Toggle("Без цензуры", isOn: $uncensor)
            } footer: {
                Text("Вместо версий с вырезанными словами играют оригинальные — из открытого списка FckCensor. Треки, удалённые из Яндекса, но оставшиеся в списке, снова доступны.")
            }
            Section("Качество звука") {
                Picker("При прослушивании", selection: $streamQuality) {
                    qualities
                }
                Picker("При скачивании", selection: $downloadQuality) {
                    qualities
                }
            }
            Section {
                LabeledContent("Скачанная музыка", value: Storage.sizeText(downloads.totalBytes))
                LabeledContent("Кэш", value: Storage.sizeText(cacheBytes))
                Button("Очистить кэш") {
                    Storage.clear(Storage.stream)
                    Storage.clear(Storage.images)
                    cacheBytes = 0
                }
                Button("Удалить всю скачанную музыку", role: .destructive) {
                    confirmRemove = true
                }
                .disabled(downloads.entries.isEmpty)
            } header: {
                Text("Память")
            } footer: {
                Text("Скачанная музыка хранится в памяти приложения и не удаляется системой. Кэш iOS может очистить сама, если место закончится.")
            }
            Section {
                Button("Выйти из аккаунта", role: .destructive) {
                    confirmLogout = true
                }
            }
            Section {
                LabeledContent("Версия", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: uncensor) { value in
            Settings.uncensor = value
            // В кэше потока могли остаться файлы другой версии трека.
            Storage.clear(Storage.stream)
            if value {
                Task { await Uncensor.shared.refresh() }
            }
        }
        .onChange(of: streamQuality) { Settings.streamQuality = $0 }
        .onChange(of: downloadQuality) { Settings.downloadQuality = $0 }
        .task {
            cacheBytes = await Task.detached { Storage.size(of: Storage.stream) + Storage.size(of: Storage.images) }.value
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { session.logout() }
        } message: {
            Text("Скачанная музыка останется на устройстве.")
        }
        .confirmationDialog("Удалить всю скачанную музыку?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { downloads.removeAll() }
        }
    }

    @ViewBuilder private var qualities: some View {
        Text("Высокое").tag("lossless")
        Text("Обычное").tag("nq")
        Text("Экономное").tag("lq")
    }
}
