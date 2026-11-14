import SwiftUI

/// Вкладка результатов поиска: что запрашивать и сколько.
enum SearchTab: String, CaseIterable, Identifiable {
    case all, tracks, artists, albums, playlists, podcasts, lyrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Всё"
        case .tracks: return "Треки"
        case .artists: return "Исполнители"
        case .albums: return "Альбомы"
        case .playlists: return "Плейлисты"
        case .podcasts: return "Подкасты"
        case .lyrics: return "По тексту"
        }
    }

    var types: String {
        switch self {
        case .all: return "track,album,artist,playlist,podcast,podcast_episode"
        case .tracks: return "track"
        case .artists: return "artist"
        case .albums: return "album"
        case .playlists: return "playlist"
        case .podcasts: return "album,artist,playlist,track,wave,podcast,podcast_episode"
        case .lyrics: return "track"
        }
    }

    var filter: String? { self == .podcasts ? "podcast" : nil }
}

struct SearchScreen: View {
    private struct Request: Equatable {
        let text: String
        let tab: SearchTab
    }

    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: Downloads
    @Environment(\.navigate) private var navigate
    @State private var query = Demo.screen == "search" ? "queen" : ""
    @State private var tab = SearchTab.all
    @State private var result = SearchResult()
    @State private var displayed: Request?
    @State private var completedPage = -1
    @State private var requestedPage = 0
    @State private var retryCount = 0
    @State private var failure: String?
    @State private var suggestions: [String] = []
    @State private var suggestedFor = ""
    /// Волны по жанрам: показаны, пока в поиске ничего не набрано.
    @State private var genres: [WaveCard] = []
    @State private var collections: [Playlist] = []
    @State private var recent = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    @FocusState private var focused: Bool

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: Request { Request(text: text, tab: tab) }

    var body: some View {
        let request = request
        let page = requestedPage
        List {
            if text.isEmpty {
                tabs
                if !recent.isEmpty {
                    history
                }
                if !genres.isEmpty {
                    title("Жанры")
                    WaveGrid(waves: genres)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
                }
                if !collections.isEmpty {
                    row {
                        Shelf("Подборки") {
                            ForEach(collections) { playlist in
                                HomeCard(item: .playlist(playlist))
                            }
                        }
                    }
                } else if recent.isEmpty && genres.isEmpty {
                    Placeholder(icon: "magnifyingglass", title: "Найдётся всё", text: "Треки, альбомы, исполнители и плейлисты")
                }
            } else {
                if tab != .lyrics, suggestedFor == text, !suggestions.isEmpty {
                    hints
                }
                tabs
                if displayed != request || (completedPage < 0 && failure == nil) {
                    RowsSkeleton(count: 8)
                } else if completedPage < 0, let failure {
                    Placeholder(icon: "wifi.slash", title: "Не удалось выполнить поиск", text: failure) { retryCount += 1 }
                } else if result.isEmpty {
                    Placeholder(
                        icon: "magnifyingglass", title: "Ничего не найдено",
                        text: tab == .lyrics ? "Попробуйте другую строку из песни." : ""
                    )
                } else {
                    switch tab {
                    case .all: everything
                    case .tracks, .lyrics: tracks(result.tracks)
                    case .artists: grid(result.artists.map { .artist($0) })
                    case .albums: grid(result.albums.map { .album($0) })
                    case .playlists: grid(result.playlists.map { .playlist($0) })
                    case .podcasts:
                        if !result.podcasts.isEmpty { grid(result.podcasts.map { .album($0) }) }
                        if !result.episodes.isEmpty {
                            title("Выпуски")
                            tracks(result.episodes, context: "Подкасты")
                        }
                    }
                }
                if tab != .all, displayed == request, completedPage >= 0, result.hasMore {
                    pagination
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .safeAreaInset(edge: .top, spacing: 0) { field }
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.immediately)
        .task(id: [request.text, request.tab.rawValue, String(page), String(retryCount)]) {
            await search(request, page: page)
        }
        .task(id: request.tab == .lyrics ? "" : request.text) {
            if request.tab != .lyrics { await suggest() }
        }
        .task {
            guard genres.isEmpty else { return }
            genres = (try? await API.shared.stations())?.first { $0.id == "genre" }?.waves ?? []
        }
        .task(id: text.isEmpty) {
            guard text.isEmpty, collections.isEmpty else { return }
            await loadCollections()
        }
        .onChange(of: request) { _ in requestedPage = 0 }
        .onChange(of: query) { value in
            // В поиск вставили ссылку на Яндекс Музыку: открываем то, на что она ведёт.
            guard let url = Links.url(in: value) else { return }
            query = ""
            Task {
                if let route = await Links.route(for: url) { navigate(route) }
            }
        }
    }

    /// Строка поиска: всегда стеклянная, список растворяется под ней.
    private var field: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel("Поиск")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.dim)
                TextField(tab == .lyrics ? "Строка из песни" : "Трек, альбом, исполнитель", text: $query)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { remember() }
                    .font(.scaled(size: 17))
                    .foregroundStyle(Theme.text)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .accessibilityLabel("Очистить")
                            .foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .glass(in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { focused = true }
            if focused || !query.isEmpty {
                Button {
                    query = ""
                    focused = false
                    tab = .all
                } label: {
                    Text("Отмена")
                        .font(.scaled(size: 16, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: focused || !query.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                stops: [
                    .init(color: Theme.background, location: 0),
                    .init(color: Theme.background.opacity(0.92), location: 0.7),
                    .init(color: Theme.background.opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - Подсказки

    /// Варианты продолжения запроса: лента над вкладками, нажатие подставляет запрос.
    private var hints: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { item in
                    Button {
                        query = item
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .accessibilityLabel("Поиск")
                                .font(.system(size: 12, weight: .semibold))
                            Text(item)
                                .font(.scaled(size: 14, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .overlay(Capsule().strokeBorder(Theme.text.opacity(0.18)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 2, trailing: 0))
    }

    private func suggest() async {
        let asked = text
        suggestions = []
        guard asked.count > 1 else {
            suggestions = []
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if Task.isCancelled { return }
        let found = (try? await API.shared.suggest(asked)) ?? []
        if Task.isCancelled || asked != text { return }
        suggestions = Array(found.filter { $0.caseInsensitiveCompare(asked) != .orderedSame }.prefix(8))
        suggestedFor = asked
    }

    // MARK: - Вкладки

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchTab.allCases) { item in
                    let on = item == tab
                    Button {
                        guard item != tab else { return }
                        tab = item
                    } label: {
                        Text(item.title)
                            .font(.scaled(size: 15, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Theme.text)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
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
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 8, trailing: 0))
    }

    // MARK: - Результаты

    @ViewBuilder private var everything: some View {
        if let best = result.best {
            title("Лучший результат")
            BestCard(best: best) {
                remember()
                open(best)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        }
        if !result.tracks.isEmpty {
            title("Треки", more: result.tracks.count > 5 || result.hasMore ? .tracks : nil)
            tracks(result.tracks, limit: 5)
        }
        if !result.artists.isEmpty {
            row {
                Shelf("Исполнители", more: result.artists.count > 3 || result.hasMore ? { tab = .artists } : nil) {
                    ForEach(result.artists) { card in
                        HomeCard(item: .artist(card), size: 116)
                    }
                }
            }
        }
        if !result.albums.isEmpty {
            row {
                Shelf("Альбомы", more: result.albums.count > 3 || result.hasMore ? { tab = .albums } : nil) {
                    ForEach(result.albums) { card in
                        HomeCard(item: .album(card))
                    }
                }
            }
        }
        if !result.playlists.isEmpty {
            row {
                Shelf("Плейлисты", more: result.playlists.count > 3 || result.hasMore ? { tab = .playlists } : nil) {
                    ForEach(result.playlists) { playlist in
                        HomeCard(item: .playlist(playlist))
                    }
                }
            }
        }
        if !result.podcasts.isEmpty {
            row {
                Shelf("Подкасты", more: { tab = .podcasts }) {
                    ForEach(result.podcasts) { podcast in
                        HomeCard(item: .album(podcast))
                    }
                }
            }
        }
        if !result.episodes.isEmpty {
            title("Выпуски", more: .podcasts)
            tracks(result.episodes, limit: 5, context: "Подкасты")
        }
    }

    private func tracks(_ list: [Track], limit: Int? = nil, context: String = "Поиск") -> some View {
        ForEach(Array(list.prefix(limit ?? list.count).enumerated()), id: \.offset) { index, track in
            TrackRow(track: track) {
                remember()
                player.play(list, at: index, context: .various(context))
            }
        }
    }

    private func grid(_ items: [HomeItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
            ForEach(items) { item in
                HomeCard(item: item, size: 160)
            }
        }
        .padding(.horizontal, 16)
        .simultaneousGesture(TapGesture().onEnded { remember() })
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }

    private func open(_ best: SearchBest) {
        switch best {
        case .track(let track): player.play([track], context: .various("Поиск"))
        case .artist(let card): navigate(.artist(card.id, card.title))
        case .album(let card), .podcast(let card): navigate(.album(card.id))
        case .playlist(let playlist): navigate(.playlist(playlist))
        }
    }

    // MARK: - Недавние запросы

    @ViewBuilder private var history: some View {
        HStack {
            Text("Вы искали")
                .font(.scaled(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                recent = []
                UserDefaults.standard.removeObject(forKey: "recentSearches")
            } label: {
                Text("Очистить")
                    .font(.scaled(size: 15, weight: .medium))
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
                        .font(.scaled(size: 16))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.dim)
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
        guard text.count > 1, !Demo.on else { return }
        var list = recent.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        list.insert(text, at: 0)
        recent = Array(list.prefix(12))
        UserDefaults.standard.set(recent, forKey: "recentSearches")
    }

    // MARK: - Оформление

    private func title(_ text: String, more: SearchTab? = nil) -> some View {
        HStack {
            Text(text)
                .font(.scaled(size: 22, weight: .bold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let more {
                Button {
                    tab = more
                } label: {
                    Text("Все")
                        .font(.scaled(size: 15, weight: .medium))
                        .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
            }
        }
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

    private var pagination: some View {
        HStack {
            Spacer()
            if requestedPage > completedPage && failure == nil {
                ProgressView()
                    .accessibilityLabel("Загрузка результатов")
            } else {
                Button(failure == nil ? "Показать ещё" : "Повторить загрузку") {
                    if failure != nil {
                        retryCount += 1
                    } else {
                        requestedPage = completedPage + 1
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentText)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func loadCollections() async {
        let cached = Demo.on ? nil : Storage.load("home.json", as: HomePage.self)
        let home: HomePage?
        if let cached { home = cached } else { home = try? await API.shared.home() }
        guard !Task.isCancelled, let home else { return }
        var ids = Set<String>()
        collections = Array(home.blocks.flatMap(\.items).compactMap { item -> Playlist? in
            guard case .playlist(let playlist) = item, ids.insert(playlist.id).inserted else { return nil }
            return playlist
        }.prefix(12))
    }

    private func search(_ asked: Request, page: Int) async {
        guard asked == request, !Task.isCancelled else { return }
        if displayed != asked {
            displayed = asked
            result = SearchResult()
            completedPage = -1
        }
        guard !asked.text.isEmpty else { return }
        guard page == completedPage + 1 else { return }
        failure = nil
        do {
            if page == 0 { try await Task.sleep(nanoseconds: 350_000_000) }
            var byLine: [Track] = []
            var lineError: Error?
            if asked.tab == .lyrics, page == 0 {
                let tracks = downloads.tracks + (Settings.offlineMode ? [] : player.queue)
                let lookup = Task.detached(priority: .userInitiated) {
                    API.searchSavedLyrics(asked.text, in: tracks)
                }
                byLine = await withTaskCancellationHandler {
                    await lookup.value
                } onCancel: {
                    lookup.cancel()
                }
                try Task.checkCancellation()
                if !Settings.offlineMode || Demo.on {
                    do {
                        byLine += try await API.shared.searchTracksByLine(asked.text)
                    } catch {
                        lineError = error
                    }
                }
                if Settings.offlineMode && !Demo.on {
                    guard !Task.isCancelled, request == asked else { return }
                    result = SearchResult(tracks: byLine)
                    completedPage = page
                    return
                }
            }
            try Task.checkCancellation()
            let found: SearchResult
            do {
                found = try await API.shared.search(asked.text, types: asked.tab.types, filter: asked.tab.filter, page: page, size: 36)
            } catch {
                guard !byLine.isEmpty else { throw error }
                guard !Task.isCancelled, request == asked else { return }
                result = SearchResult()
                result.append(SearchResult(tracks: byLine))
                completedPage = page
                return
            }
            guard !Task.isCancelled, request == asked else { return }
            if found.isEmpty, byLine.isEmpty, let lineError { throw lineError }
            if page == 0 {
                result = SearchResult(best: found.best)
                result.append(SearchResult(tracks: byLine))
            }
            result.append(found)
            completedPage = page
        } catch {
            guard !Task.isCancelled, request == asked else { return }
            failure = error.localizedDescription
        }
    }
}

/// «Лучший результат»: первое, что нашёл Яндекс, крупной карточкой.
private struct BestCard: View {
    let best: SearchBest
    let action: () -> Void

    @ObservedObject private var now = Player.shared.now

    /// Этот трек сейчас в плеере.
    private var current: Bool {
        if case .track(let track) = best { return now.id == track.id }
        return false
    }

    private var content: (cover: String?, title: String, kind: String, round: Bool, symbol: String) {
        switch best {
        case .track(let track): return (track.cover, track.fullTitle, "Трек · \(track.artists)", false, "play.fill")
        case .artist(let card): return (card.cover, card.title, "Исполнитель", true, "chevron.right")
        case .album(let card): return (card.cover, card.title, card.subtitle.isEmpty ? "Альбом" : "Альбом · \(card.subtitle)", false, "chevron.right")
        case .playlist(let playlist): return (playlist.cover, playlist.title, "Плейлист", false, "chevron.right")
        case .podcast(let card): return (card.cover, card.title, "Подкаст", false, "chevron.right")
        }
    }

    var body: some View {
        let item = content
        Button(action: action) {
            HStack(spacing: 14) {
                CoverView(uri: item.cover, size: 76, corner: 12, round: item.round)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.scaled(size: 19, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text(item.kind)
                        .font(.scaled(size: 14))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.symbol == "play.fill" {
                    let on = current
                    ZStack {
                        if on, now.playing {
                            PlayingBars(playing: true, size: 16, color: .black)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            PlayGlyph(playing: false, size: 15)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .foregroundStyle(Color.black)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: on && now.playing)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 38, height: 38)
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.97))
    }
}
