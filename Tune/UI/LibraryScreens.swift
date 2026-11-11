import SwiftUI

// MARK: - Поиск

struct SearchScreen: View {
    @EnvironmentObject private var player: Player
    @Environment(\.navigate) private var navigate
    @State private var query = Demo.screen == "search" ? "queen" : ""
    @State private var result = SearchResult()
    @State private var loading = false
    @State private var failed = false
    @State private var recent = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if recent.isEmpty {
                    Placeholder(icon: "magnifyingglass", title: "Найдётся всё", text: "Треки, альбомы, исполнители и плейлисты")
                } else {
                    history
                }
            } else if failed && result.isEmpty {
                Placeholder(icon: "wifi.slash", title: "Не удалось выполнить поиск")
            } else if result.isEmpty {
                if loading {
                    Spinner()
                } else {
                    Placeholder(icon: "magnifyingglass", title: "Ничего не найдено")
                }
            } else {
                if !result.artists.isEmpty {
                    row {
                        Shelf("Исполнители") {
                            ForEach(result.artists) { card in
                                HomeCard(item: .artist(card), size: 116)
                            }
                        }
                    }
                }
                if !result.tracks.isEmpty {
                    title("Треки")
                    ForEach(Array(result.tracks.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track) {
                            remember()
                            player.play(result.tracks, at: index, context: .various("Поиск"))
                        }
                    }
                }
                if !result.albums.isEmpty {
                    row {
                        Shelf("Альбомы") {
                            ForEach(result.albums) { card in
                                HomeCard(item: .album(card))
                            }
                        }
                    }
                }
                if !result.playlists.isEmpty {
                    row {
                        Shelf("Плейлисты") {
                            ForEach(result.playlists) { playlist in
                                HomeCard(item: .playlist(playlist))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Поиск")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Трек, альбом, исполнитель")
        .autocorrectionDisabled()
        .scrollDismissesKeyboard(.immediately)
        .onSubmit(of: .search) { remember() }
        .task(id: query) { await search() }
    }

    /// Недавние запросы: показываются, пока строка поиска пуста.
    @ViewBuilder private var history: some View {
        HStack {
            Text("Вы искали")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                recent = []
                UserDefaults.standard.removeObject(forKey: "recentSearches")
            } label: {
                Text("Очистить")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
        ForEach(recent, id: \.self) { text in
            Button {
                query = text
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Theme.dim)
                    Text(text)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
    }

    private func remember() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count > 1, !Demo.on else { return }
        var list = recent.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        list.insert(text, at: 0)
        recent = Array(list.prefix(12))
        UserDefaults.standard.set(recent, forKey: "recentSearches")
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .simultaneousGesture(TapGesture().onEnded { remember() })
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 8, trailing: 0))
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
    @Environment(\.navigate) private var navigate
    @State private var creating = false
    @State private var name = ""
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let version = updater.latest {
                    Button {
                        navigate(.settings)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.accent)
                            Text("Доступна версия \(version)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer(minLength: 0)
                            Text("Обновить")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(14)
                        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                Button {
                    navigate(.likes)
                } label: {
                    HStack(spacing: 16) {
                        SymbolCover(symbol: "heart.fill", colors: SymbolCover.likes, size: 92, corner: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Мне нравится")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Text(plural(session.likedIds.count, "трек", "трека", "треков"))
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.dim)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)

                entry("arrow.down.circle.fill", "Скачанные треки", downloads.entries.isEmpty ? "" : "\(downloads.entries.count)", .downloads)
                entry("square.stack.fill", "Альбомы", session.likedAlbums.isEmpty ? "" : "\(session.likedAlbums.count)", .likedAlbums)
                entry("music.mic", "Исполнители", session.likedArtists.isEmpty ? "" : "\(session.likedArtists.count)", .likedArtists)
                entry("clock.arrow.circlepath", "История", "", .history)

                HStack {
                    Text("Плейлисты")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        name = ""
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .glass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 26)
                .padding(.bottom, 10)

                if session.playlists.isEmpty && session.likedPlaylists.isEmpty {
                    Text("Создайте плейлист или добавьте чужой в коллекцию — он появится здесь.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                }
                ForEach(session.playlists) { playlist in
                    playlistRow(playlist, own: true)
                }
                ForEach(session.likedPlaylists) { playlist in
                    playlistRow(playlist, own: false)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Коллекция")
        .refreshable {
            await Task {
                await session.refresh()
                await Updater.shared.check()
            }.value
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    navigate(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .alert("Новый плейлист", isPresented: $creating) {
            TextField("Название", text: $name)
            Button("Создать") {
                let title = name
                Task {
                    if let playlist = await session.createPlaylist(title) { navigate(.playlist(playlist)) }
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func playlistRow(_ playlist: Playlist, own: Bool) -> some View {
        Button {
            navigate(.playlist(playlist))
        } label: {
            HStack(spacing: 12) {
                CoverView(uri: playlist.cover, size: 56, corner: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(own ? plural(playlist.count, "трек", "трека", "треков") : (playlist.count > 0 ? "Добавлен · \(plural(playlist.count, "трек", "трека", "треков"))" : "Добавлен в коллекцию"))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func entry(_ icon: String, _ title: String, _ value: String, _ route: Route) -> some View {
        Button {
            navigate(route)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.dim)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.dim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// Выбор плейлиста, в который добавить трек.
struct PlaylistPicker: View {
    let track: Track

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    name = ""
                    creating = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 50, height: 50)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("Новый плейлист")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                ForEach(session.playlists) { playlist in
                    Button {
                        Task { await session.add(track, to: playlist) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            CoverView(uri: playlist.cover, size: 50, corner: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.title)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(plural(playlist.count, "трек", "трека", "треков"))
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.dim)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Добавить в плейлист")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .alert("Новый плейлист", isPresented: $creating) {
                TextField("Название", text: $name)
                Button("Создать") {
                    let title = name
                    Task {
                        if let playlist = await session.createPlaylist(title) {
                            await session.add(track, to: playlist)
                        }
                    }
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .tint(.white)
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Альбомы и исполнители из коллекции

struct CardGridScreen: View {
    enum Kind {
        case albums, artists
    }

    let kind: Kind

    @EnvironmentObject private var session: Session
    @State private var cards: [Card]?
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let cards {
                if cards.isEmpty {
                    Placeholder(icon: kind == .albums ? "square.stack" : "music.mic", title: "Здесь пока пусто", text: kind == .albums ? "Нажмите на сердечко на странице альбома, чтобы добавить его сюда." : "Нажмите на сердечко на странице исполнителя, чтобы добавить его сюда.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
                        ForEach(cards) { card in
                            HomeCard(item: kind == .albums ? .album(card) : .artist(card), size: 160)
                        }
                    }
                    .padding(16)
                }
            } else if let error {
                Placeholder(icon: "wifi.slash", title: "Не удалось загрузить", text: error) {
                    Task { await load() }
                }
            } else {
                Spinner()
            }
        }
        .background(Theme.background)
        .navigationTitle(kind == .albums ? "Альбомы" : "Исполнители")
        .navigationBarTitleDisplayMode(.inline)
        .task { if cards == nil { await load() } }
    }

    private func load() async {
        error = nil
        if session.profile == nil {
            await session.refresh()
        }
        guard let uid = session.profile?.uid else {
            error = "Нет связи с Яндексом"
            return
        }
        do {
            if kind == .albums {
                cards = try await API.shared.likedAlbums(uid: uid)
            } else {
                cards = try await API.shared.likedArtists(uid: uid)
            }
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
    @Environment(\.navigate) private var navigate
    @State private var uncensor = Settings.uncensor
    @State private var streamQuality = Settings.streamQuality
    @State private var downloadQuality = Settings.downloadQuality
    @State private var cacheBytes: Int64 = 0
    @State private var confirmLogout = false
    @State private var confirmRemove = false
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Form {
            if let version = updater.latest {
                Section {
                    Button("Обновить через AltStore") { updater.install(with: "altstore") }
                    Button("Обновить через SideStore") { updater.install(with: "sidestore") }
                    Button("Скачать файл .ipa") { updater.download() }
                } header: {
                    Text("Доступна версия \(version)")
                } footer: {
                    Text("Установка идёт поверх: вход, настройки и скачанная музыка сохраняются.")
                }
                .tint(Theme.accent)
            }
            Section("Аккаунт") {
                LabeledContent("Имя", value: session.profile?.name ?? "—")
                LabeledContent("Плюс", value: session.profile?.plus == true ? "Активен" : "Нет")
            }
            Section {
                Toggle("Без цензуры", isOn: $uncensor)
                    .tint(Theme.accent)
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
                Button("Журнал ошибок") {
                    navigate(.log)
                }
                LabeledContent("Версия", value: Self.version)
            }
            Section {
                Button("Выйти из аккаунта", role: .destructive) {
                    confirmLogout = true
                }
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
        .alert("Выйти из аккаунта?", isPresented: $confirmLogout) {
            Button("Отмена", role: .cancel) {}
            Button("Выйти", role: .destructive) { session.logout() }
        } message: {
            Text("Скачанная музыка останется на устройстве.")
        }
        .alert("Удалить всю скачанную музыку?", isPresented: $confirmRemove) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) { downloads.removeAll() }
        }
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(short) (\(build))"
    }

    @ViewBuilder private var qualities: some View {
        Text("Высокое").tag("lossless")
        Text("Обычное").tag("nq")
        Text("Экономное").tag("lq")
    }
}

/// Журнал ошибок: его можно скопировать и прислать разработчику.
struct LogScreen: View {
    @State private var text = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Ошибок не было." : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(text.isEmpty ? Theme.dim : Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .background(Theme.background)
        .navigationTitle("Журнал ошибок")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(copied ? "Скопировано" : "Скопировать") {
                    UIPasteboard.general.string = "Tune \(SettingsScreen.version)\n\(text)"
                    copied = true
                }
                .disabled(text.isEmpty)
            }
        }
        .onAppear { text = Log.shared.text }
    }
}
