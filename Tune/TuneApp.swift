import SwiftUI

@main
struct TuneApp: App {
    @StateObject private var session = Session.shared
    @StateObject private var player = Player.shared
    @StateObject private var downloads = Downloads.shared

    init() {
        Uncensor.shared.start()
        // На iOS 26 панели стеклянные сами по себе; на старых системах делаем их тёмными
        // и полупрозрачными, чтобы кнопки читались поверх прокрученного списка.
        if #unavailable(iOS 26.0) {
            let tabs = UITabBarAppearance()
            tabs.configureWithOpaqueBackground()
            tabs.backgroundColor = .black
            tabs.shadowColor = .clear
            UITabBar.appearance().standardAppearance = tabs
            UITabBar.appearance().scrollEdgeAppearance = tabs
            UITabBar.appearance().unselectedItemTintColor = UIColor(white: 0.55, alpha: 1)

            let scrolled = UINavigationBarAppearance()
            scrolled.configureWithTransparentBackground()
            scrolled.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
            scrolled.shadowColor = .clear
            let top = UINavigationBarAppearance()
            top.configureWithTransparentBackground()
            UINavigationBar.appearance().standardAppearance = scrolled
            UINavigationBar.appearance().compactAppearance = scrolled
            UINavigationBar.appearance().scrollEdgeAppearance = top
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
                .tint(.white)
                .task { await Updater.shared.check() }
                .task {
                    await session.refresh()
                    if Demo.on {
                        player.showDemo(Demo.data.tracks, name: "Мне нравится")
                    }
                }
        }
    }
}

enum Route: Hashable {
    case likes
    case downloads
    case history
    case playlist(Playlist)
    case album(String)
    case artist(String, String)
    case artistTracks(String, String)
    case likedAlbums
    case likedArtists
    case settings
    case log
}

private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (Route) -> Void = { _ in }
}

private struct OpenPlayerKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Открыть страницу во вкладке, где находится вид.
    var navigate: (Route) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }

    var openPlayer: () -> Void {
        get { self[OpenPlayerKey.self] }
        set { self[OpenPlayerKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @StateObject private var router = Router.shared
    @State private var showPlayer = ["player", "queue", "lyrics"].contains(Demo.screen)
    @State private var picking: Track? = Demo.screen == "picker" ? Demo.data.tracks.first : nil
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if session.token == nil {
                LoginScreen()
            } else {
                tabs
            }
        }
        .onChange(of: phase) { now in
            if now == .active { Task { await Updater.shared.check() } }
        }
        .alert("Tune", isPresented: errorShown) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(player.errorText ?? "")
        }
    }

    private static let rise = Animation.spring(response: 0.36, dampingFraction: 1)
    private static let fall = Animation.easeInOut(duration: 0.26)

    private var errorShown: Binding<Bool> {
        Binding(get: { player.errorText != nil }, set: { if !$0 { player.errorText = nil } })
    }

    private var tabs: some View {
        TabView(selection: $router.tab) {
            TabRoot(index: 0) { HomeScreen() }
                .tabItem { Label("Главная", systemImage: "house.fill") }
                .tag(0)
            TabRoot(index: 1) { SearchScreen() }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                .tag(1)
            TabRoot(index: 2) { LibraryScreen() }
                .tabItem { Label("Коллекция", systemImage: "heart.fill") }
                .tag(2)
        }
        .tint(Theme.accent)
        // Пока открыт плеер, вкладки под ним не принимают нажатия: иначе кнопка «назад»
        // страницы срабатывала вместо кнопки плеера над ней.
        .allowsHitTesting(!showPlayer)
        .environmentObject(router)
        .environment(\.openPlayer, { withAnimation(Self.rise) { showPlayer = true } })
        .environment(\.pickPlaylist, { picking = $0 })
        .overlay(alignment: .top) {
            ToastView()
        }
        .sheet(item: $picking) { track in
            PlaylistPicker(track: track)
        }
        .overlay {
            if showPlayer {
                PlayerScreen(close: { withAnimation(Self.fall) { showPlayer = false } })
                    .environmentObject(router)
                    // Сдвиг на всю высоту экрана: фон плеера выходит за безопасную область,
                    // и при сдвиге только на высоту содержимого его край оставался на виду.
                    .transition(.offset(y: UIScreen.main.bounds.height + 60))
            }
        }
    }
}

/// Вкладка со своей историей переходов и мини-плеером над панелью вкладок.
struct TabRoot<Content: View>: View {
    let index: Int
    private let content: Content
    @EnvironmentObject private var router: Router

    init(index: Int, @ViewBuilder content: () -> Content) {
        self.index = index
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $router.paths[index]) {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerSpace() }
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerSpace() }
                }
        }
        .tint(.white)
        .environment(\.navigate, { router.paths[index].append($0) })
        // Мини-плеер лежит поверх страницы, а место под него отступает каждая страница сама:
        // так список докручивается до конца и последние строки не прячутся.
        .overlay(alignment: .bottom) {
            MiniPlayer()
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .likes: TrackListScreen(kind: .likes)
        case .downloads: TrackListScreen(kind: .downloads)
        case .history: TrackListScreen(kind: .history)
        case .playlist(let playlist): TrackListScreen(kind: .playlist(playlist))
        case .album(let id): TrackListScreen(kind: .album(id))
        case .artistTracks(let id, let name): TrackListScreen(kind: .artist(id, name))
        case .artist(let id, let name): ArtistScreen(id: id, name: name)
        case .likedAlbums: CardGridScreen(kind: .albums)
        case .likedArtists: CardGridScreen(kind: .artists)
        case .settings: SettingsScreen()
        case .log: LogScreen()
        }
    }
}
