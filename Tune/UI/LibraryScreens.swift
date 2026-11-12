import SwiftUI

// MARK: - Коллекция

struct LibraryScreen: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.navigate) private var navigate
    @State private var creating = false
    @State private var name = ""
    @AppStorage("playlistsByName") private var byName = false
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

                entry("arrow.down.circle.fill", "Скачанные треки", downloadsValue, .downloads)
                entry("square.stack.fill", "Альбомы", session.likedAlbums.isEmpty ? "" : "\(session.likedAlbums.count)", .likedAlbums)
                entry("music.mic", "Исполнители", session.likedArtists.isEmpty ? "" : "\(session.likedArtists.count)", .likedArtists)
                entry("clock.arrow.circlepath", "История", "", .history)
                entry("chart.bar.fill", "Статистика", "", .stats)
                if !session.disliked.isEmpty {
                    entry("hand.thumbsdown.fill", "Не нравится", "\(session.disliked.count)", .disliked)
                }

                HStack {
                    Text("Плейлисты")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        byName.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                            Text(byName ? "По названию" : "Недавние")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(Theme.dim)
                        .padding(.trailing, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                ForEach(ordered(session.playlists)) { playlist in
                    playlistRow(playlist, own: true)
                }
                ForEach(ordered(session.likedPlaylists)) { playlist in
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

    private func ordered(_ list: [Playlist]) -> [Playlist] {
        byName ? list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } : list
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

    private var downloadsValue: String {
        if !downloads.queue.isEmpty { return "ещё \(downloads.queue.count) в очереди" }
        return downloads.entries.isEmpty ? "" : "\(downloads.entries.count)"
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
    let tracks: [Track]

    init(track: Track) {
        tracks = [track]
    }

    init(tracks: [Track]) {
        self.tracks = tracks
    }

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
                        Task { await session.add(tracks, to: playlist) }
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
            .navigationTitle(tracks.count == 1 ? "Добавить в плейлист" : "Добавить в плейлист: \(tracks.count)")
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
                            await session.add(tracks, to: playlist)
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

/// Все карточки полки главной сеткой.
struct ItemGridScreen: View {
    let title: String
    let items: [HomeItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(items) { item in
                    HomeCard(item: item, size: 160)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var wifiOnly = Settings.wifiOnly
    @State private var autoLikes = Settings.autoLikes
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
                Toggle("Только по Wi-Fi", isOn: $wifiOnly)
                Toggle("Скачивать «Мне нравится»", isOn: $autoLikes)
            } header: {
                Text("Загрузки")
            } footer: {
                Text("С включённым «Только по Wi-Fi» загрузки в сотовой сети ждут в очереди. Лайкнутые треки скачиваются сами: новые — сразу, остальные — когда откроете «Мне нравится».")
            }
            .tint(Theme.accent)
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
        .onChange(of: wifiOnly) { value in
            Settings.wifiOnly = value
            downloads.settingsChanged()
        }
        .onChange(of: autoLikes) { value in
            Settings.autoLikes = value
            guard value else { return }
            Task {
                // Список лайков, сохранённый с прошлого открытия «Мне нравится».
                let cached = await Task.detached { Storage.load("likes-tracks.json", as: [Track].self) }.value ?? []
                downloads.auto(cached.filter { session.isLiked($0.id) })
            }
        }
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
