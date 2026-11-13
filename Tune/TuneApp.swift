import SwiftUI

/// Быстрые действия: меню по долгому нажатию на значок приложения.
@MainActor
enum QuickAction {
    /// Действие, с которым приложение запустили: выполняется, когда всё готово.
    static var pending: String?

    static func run(_ type: String) {
        switch type {
        case "wave":
            Player.shared.playWave()
        case "search":
            PlayerWindow.shared.hide()
            Router.shared.tab = 1
        case "likes":
            PlayerWindow.shared.hide()
            Router.shared.tab = 2
            Router.shared.paths[2] = [.likes]
        default:
            break
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickAction.pending = item.type }
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// Система разбудила приложение: фоновые загрузки завершились.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundFetcher.shared.setWake(completionHandler)
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor item: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        QuickAction.run(item.type)
        completionHandler(true)
    }
}

@main
struct TuneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
            tabs.backgroundColor = .systemBackground
            tabs.shadowColor = .clear
            UITabBar.appearance().standardAppearance = tabs
            UITabBar.appearance().scrollEdgeAppearance = tabs
            UITabBar.appearance().unselectedItemTintColor = UIColor.secondaryLabel

            let scrolled = UINavigationBarAppearance()
            scrolled.configureWithTransparentBackground()
            scrolled.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
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
                .tint(Theme.text)
                .onAppear { Appearance.apply() }
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .task { await Updater.shared.check() }
                .task {
                    await session.refresh()
                    Task { await downloads.syncPlaylists() }
                    if let action = QuickAction.pending {
                        QuickAction.pending = nil
                        QuickAction.run(action)
                    }
                    if Demo.on {
                        player.showDemo(Demo.data.tracks, name: "Мне нравится")
                        if ["player", "queue", "lyrics", "actions"].contains(Demo.screen) {
                            // Окно плеера создаётся, когда сцена уже на экране.
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            PlayerWindow.shared.show(animated: false)
                        }
                    }
                }
        }
    }
}

enum Route: Hashable {
    case likes
    case downloads
    case history
    case disliked
    case playlist(Playlist)
    case album(String)
    case artist(String, String)
    case artistTracks(String, String)
    case block(HomeBlock)
    case likedAlbums
    case likedArtists
    case settings
    case log
    case stats
    case storage
    case stations
    case changes
}

private struct NavigateKey: EnvironmentKey {
    static let defaultValue: (Route) -> Void = { _ in }
}

private struct OpenPlayerKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct ClosePlayerKey: EnvironmentKey {
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

    var closePlayer: () -> Void {
        get { self[ClosePlayerKey.self] }
        set { self[ClosePlayerKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var player: Player
    @StateObject private var router = Router.shared
    @ObservedObject private var playerWindow = PlayerWindow.shared
    @State private var picking: Track? = Demo.screen == "picker" ? Demo.data.tracks.first : nil
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if session.token == nil || session.adding {
                LoginScreen()
                    .environment(\.colorScheme, .dark)
            } else {
                // Другой аккаунт — другие страницы: всё строится заново.
                // И другой размер системного шрифта: текст пересчитывается.
                tabs.id("\(session.epoch)-\(typeSize)")
            }
        }
        .onChange(of: phase) { now in
            if now == .active { Task { await Updater.shared.check() } }
        }
        .onOpenURL { url in
            if session.token != nil { Links.open(url) }
        }
        .alert("Tune", isPresented: errorShown) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(player.errorText ?? "")
        }
    }

    /// Пока открыт плеер, ошибку показывает его окно: оно лежит поверх этого.
    private var errorShown: Binding<Bool> {
        Binding(get: { player.errorText != nil && !playerWindow.visible }, set: { if !$0 { player.errorText = nil } })
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
        .tint(Theme.accentText)
        .environmentObject(router)
        .environment(\.openPlayer, { PlayerWindow.shared.show() })
        .environment(\.pickPlaylist, { picking = $0 })
        .overlay(alignment: .bottom) {
            ToastView(bottom: true)
        }
        .sheet(item: $picking) { track in
            PlaylistPicker(track: track)
        }
    }
}

/// Вкладка со своей историей переходов и мини-плеером над панелью вкладок.
struct TabRoot<Content: View>: View {
    let index: Int
    private let content: Content
    @EnvironmentObject private var router: Router
    /// Вкладка проявляется, когда на неё переключились.
    @State private var shown = true

    init(index: Int, @ViewBuilder content: () -> Content) {
        self.index = index
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $router.paths[index]) {
            content
                .opacity(shown ? 1 : 0)
                .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerSpace() }
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerSpace() }
                }
        }
        .tint(.white)
        .environment(\.navigate, { router.paths[index].append($0) })
        .onChange(of: router.tab) { tab in
            guard tab == index else { return }
            shown = false
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { shown = true }
            }
        }
        // Мини-плеер лежит поверх страницы, а место под него отступает каждая страница сама:
        // так список докручивается до конца и последние строки не прячутся.
        .overlay(alignment: .bottom) {
            // Мини-плеер окрашен под обложку, поэтому в любой теме тёмный.
            MiniPlayer()
                .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .likes: TrackListScreen(kind: .likes)
        case .downloads: TrackListScreen(kind: .downloads)
        case .history: TrackListScreen(kind: .history)
        case .disliked: TrackListScreen(kind: .disliked)
        case .playlist(let playlist): TrackListScreen(kind: .playlist(playlist))
        case .album(let id): TrackListScreen(kind: .album(id))
        case .artistTracks(let id, let name): TrackListScreen(kind: .artist(id, name))
        case .artist(let id, let name): ArtistScreen(id: id, name: name)
        case .block(let block): ItemGridScreen(title: block.title, items: block.items)
        case .likedAlbums: CardGridScreen(kind: .albums)
        case .likedArtists: CardGridScreen(kind: .artists)
        case .settings: SettingsScreen()
        case .log: LogScreen()
        case .stats: StatsScreen()
        case .storage: StorageScreen()
        case .stations: StationsScreen()
        case .changes: ChangesScreen()
        }
    }
}
