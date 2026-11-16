import Combine
import SwiftUI

/// Быстрые действия: меню по долгому нажатию на значок приложения.
@MainActor
enum QuickAction {
    /// Действие, с которым приложение запустили: выполняется, когда всё готово.
    static var pending: String?

    static func run(_ type: String) {
        switch type {
        case "player":
            PlayerWindow.shared.show()
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
    case dislikedArtists
    case playlist(Playlist)
    case album(String)
    case artist(String, String)
    case artistTracks(String, String)
    case artistFamiliar(String, String, Bool)
    case replacement(ReplacementTarget)
    case block(HomeBlock)
    case likedAlbums
    case likedArtists
    case likedPodcasts
    case likedBooks
    case kids
    case concerts
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
    @State private var hasTrack = Player.shared.now.id != nil
    @AppStorage("minimizeMiniPlayer") private var minimizeMiniPlayer = true

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
            if now == .active {
                Player.shared.refreshPlaybackActivity()
                Task {
                    async let update: Void = Updater.shared.check()
                    if !Demo.on, !Settings.offlineMode { await session.refresh() }
                    await update
                }
            }
        }
        .onOpenURL { url in
            guard session.token != nil else { return }
            if url.scheme == "tune", url.path.isEmpty, let action = url.host,
               ["player", "wave", "likes", "search"].contains(action) {
                QuickAction.run(action)
            } else {
                Links.open(url)
            }
        }
        .onReceive(Player.shared.now.$id.map { $0 != nil }.removeDuplicates()) { visible in
            if hasTrack != visible { hasTrack = visible }
        }
        .onReceive(Connectivity.shared.$online.dropFirst()) { online in
            guard online, !Settings.offlineMode else { return }
            Uploads.shared.resume()
            if session.offline { Task { await session.refresh() } }
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
        tabsWithPlayer
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

    @ViewBuilder private var tabsWithPlayer: some View {
        if #available(iOS 26.1, *) {
            tabPages
                .tabBarMinimizeBehavior(minimizeMiniPlayer ? .onScrollDown : .never)
                .tabViewBottomAccessory(isEnabled: hasTrack) { TabMiniPlayer() }
        } else {
            tabPages
        }
    }

    private var tabPages: some View {
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
    }
}

/// Вкладка со своей историей переходов и мини-плеером над панелью вкладок.
struct TabRoot<Content: View>: View {
    let index: Int
    private let content: Content
    @EnvironmentObject private var router: Router
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Вкладка проявляется, когда на неё переключились.
    @State private var shown = true

    init(index: Int, @ViewBuilder content: () -> Content) {
        self.index = index
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.1, *) {
            stack
        } else {
            stack.overlay(alignment: .bottom) {
                MiniPlayer(light: scheme == .light)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    private var stack: some View {
        NavigationStack(path: $router.paths[index]) {
            inset(content.opacity(shown ? 1 : 0))
                .navigationDestination(for: Route.self) { route in
                    inset(destination(route))
                }
        }
        .tint(Theme.text)
        .environment(\.navigate, { router.paths[index].append($0) })
        .onChange(of: router.tab) { tab in
            guard tab == index, !reduceMotion else { return }
            shown = false
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) { shown = true }
            }
        }
    }

    @ViewBuilder private func inset<V: View>(_ view: V) -> some View {
        if #available(iOS 26.1, *) {
            view
        } else {
            view.safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerSpace() }
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .likes: TrackListScreen(kind: .likes)
        case .downloads: TrackListScreen(kind: .downloads)
        case .history: TrackListScreen(kind: .history)
        case .disliked: TrackListScreen(kind: .disliked)
        case .dislikedArtists: DislikedArtistsScreen()
        case .playlist(let playlist): TrackListScreen(kind: .playlist(playlist))
        case .album(let id): TrackListScreen(kind: .album(id))
        case .artistTracks(let id, let name): TrackListScreen(kind: .artist(id, name))
        case .artistFamiliar(let id, let name, let wave): TrackListScreen(kind: .artistFamiliar(id, name, wave))
        case .replacement(let target): ReplacementScreen(target: target)
        case .artist(let id, let name): ArtistScreen(id: id, name: name)
        case .block(let block): ItemGridScreen(title: block.title, items: block.items)
        case .likedAlbums: CardGridScreen(kind: .albums)
        case .likedArtists: CardGridScreen(kind: .artists)
        case .likedPodcasts: CardGridScreen(kind: .podcasts)
        case .likedBooks: CardGridScreen(kind: .books)
        case .kids: KidsScreen()
        case .concerts: ConcertsScreen()
        case .settings: SettingsScreen()
        case .log: LogScreen()
        case .stats: StatsScreen()
        case .storage: StorageScreen()
        case .stations: StationsScreen()
        case .changes: ChangesScreen()
        }
    }
}
