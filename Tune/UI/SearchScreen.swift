import SwiftUI

/// Вкладка результатов поиска: что запрашивать и сколько.
enum SearchTab: String, CaseIterable, Identifiable {
    case all, tracks, artists, albums, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Всё"
        case .tracks: return "Треки"
        case .artists: return "Исполнители"
        case .albums: return "Альбомы"
        case .playlists: return "Плейлисты"
        }
    }

    var types: String {
        switch self {
        case .all: return "track,album,artist,playlist"
        case .tracks: return "track"
        case .artists: return "artist"
        case .albums: return "album"
        case .playlists: return "playlist"
        }
    }

    /// На общей вкладке всего понемногу, на своей — длинный список.
    var size: Int { self == .all ? 36 : 100 }
}

struct SearchScreen: View {
    @EnvironmentObject private var player: Player
    @Environment(\.navigate) private var navigate
    @State private var query = Demo.screen == "search" ? "queen" : ""
    @State private var tab = SearchTab.all
    @State private var result = SearchResult()
    @State private var loading = false
    @State private var failed = false
    @State private var suggestions: [String] = []
    /// Волны по жанрам: показаны, пока в поиске ничего не набрано.
    @State private var genres: [WaveCard] = []
    @State private var recent = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []

    private var text: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            if text.isEmpty {
                if !recent.isEmpty {
                    history
                }
                if !genres.isEmpty {
                    title("Жанры")
                    WaveGrid(waves: genres)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 20, trailing: 16))
                } else if recent.isEmpty {
                    Placeholder(icon: "magnifyingglass", title: "Найдётся всё", text: "Треки, альбомы, исполнители и плейлисты")
                }
            } else {
                if !suggestions.isEmpty {
                    hints
                }
                tabs
                if failed && result.isEmpty {
                    Placeholder(icon: "wifi.slash", title: "Не удалось выполнить поиск")
                } else if result.isEmpty {
                    if loading {
                        Spinner()
                    } else {
                        Placeholder(icon: "magnifyingglass", title: "Ничего не найдено")
                    }
                } else {
                    switch tab {
                    case .all: everything
                    case .tracks: tracks(result.tracks)
                    case .artists: grid(result.artists.map { .artist($0) })
                    case .albums: grid(result.albums.map { .album($0) })
                    case .playlists: grid(result.playlists.map { .playlist($0) })
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
        .task(id: query + "|" + tab.rawValue) { await search() }
        .task(id: query) { await suggest() }
        .task {
            guard genres.isEmpty, Demo.screen != "search" else { return }
            genres = (try? await API.shared.stations())?.first { $0.id == "genre" }?.waves ?? []
        }
        .onChange(of: query) { value in
            // В поиск вставили ссылку на Яндекс Музыку: открываем то, на что она ведёт.
            guard let url = Links.url(in: value) else { return }
            query = ""
            Task {
                if let route = await Links.route(for: url) { navigate(route) }
            }
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
                                .font(.system(size: 12, weight: .semibold))
                            Text(item)
                                .font(.system(size: 14, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
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
        guard asked.count > 1 else {
            suggestions = []
            return
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        if Task.isCancelled { return }
        let found = (try? await API.shared.suggest(asked)) ?? []
        if Task.isCancelled { return }
        suggestions = Array(found.filter { $0.caseInsensitiveCompare(asked) != .orderedSame }.prefix(8))
    }

    // MARK: - Вкладки

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchTab.allCases) { item in
                    let on = item == tab
                    Button {
                        guard item != tab else { return }
                        result = SearchResult()
                        tab = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(on ? Theme.accent : Theme.raised, in: Capsule())
                    }
                    .buttonStyle(.plain)
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
            title("Треки", more: result.tracks.count > 5 ? .tracks : nil)
            tracks(Array(result.tracks.prefix(5)))
        }
        if !result.artists.isEmpty {
            row {
                Shelf("Исполнители", more: result.artists.count > 3 ? { tab = .artists } : nil) {
                    ForEach(result.artists) { card in
                        HomeCard(item: .artist(card), size: 116)
                    }
                }
            }
        }
        if !result.albums.isEmpty {
            row {
                Shelf("Альбомы", more: result.albums.count > 3 ? { tab = .albums } : nil) {
                    ForEach(result.albums) { card in
                        HomeCard(item: .album(card))
                    }
                }
            }
        }
        if !result.playlists.isEmpty {
            row {
                Shelf("Плейлисты", more: result.playlists.count > 3 ? { tab = .playlists } : nil) {
                    ForEach(result.playlists) { playlist in
                        HomeCard(item: .playlist(playlist))
                    }
                }
            }
        }
    }

    private func tracks(_ list: [Track]) -> some View {
        ForEach(Array(list.enumerated()), id: \.offset) { index, track in
            TrackRow(track: track) {
                remember()
                player.play(result.tracks, at: index, context: .various("Поиск"))
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
        case .album(let card): navigate(.album(card.id))
        case .playlist(let playlist): navigate(.playlist(playlist))
        }
    }

    // MARK: - Недавние запросы

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
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if let more {
                Button {
                    result = SearchResult()
                    tab = more
                } label: {
                    Text("Все")
                        .font(.system(size: 15, weight: .medium))
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

    private func search() async {
        let asked = text
        guard !asked.isEmpty else {
            result = SearchResult()
            loading = false
            return
        }
        // Запрос уходит, когда пользователь перестал печатать.
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        loading = true
        do {
            let found = try await API.shared.search(asked, types: tab.types, size: tab.size)
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

/// «Лучший результат»: первое, что нашёл Яндекс, крупной карточкой.
private struct BestCard: View {
    let best: SearchBest
    let action: () -> Void

    private var content: (cover: String?, title: String, kind: String, round: Bool, symbol: String) {
        switch best {
        case .track(let track): return (track.cover, track.fullTitle, "Трек · \(track.artists)", false, "play.fill")
        case .artist(let card): return (card.cover, card.title, "Исполнитель", true, "chevron.right")
        case .album(let card): return (card.cover, card.title, card.subtitle.isEmpty ? "Альбом" : "Альбом · \(card.subtitle)", false, "chevron.right")
        case .playlist(let playlist): return (playlist.cover, playlist.title, "Плейлист", false, "chevron.right")
        }
    }

    var body: some View {
        let item = content
        Button(action: action) {
            HStack(spacing: 14) {
                CoverView(uri: item.cover, size: 76, corner: 12, round: item.round)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(item.kind)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.symbol == "play.fill" ? Color.black : Theme.dim)
                    .frame(width: 38, height: 38)
                    .background(item.symbol == "play.fill" ? Theme.accent : Color.clear, in: Circle())
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
