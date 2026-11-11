import SwiftUI

@main
struct TuneApp: App {
    @StateObject private var session = Session.shared
    @StateObject private var player = Player.shared
    @StateObject private var downloads = Downloads.shared

    init() {
        Uncensor.shared.start()
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = .black
        bar.shadowColor = .clear
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
        UITabBar.appearance().unselectedItemTintColor = UIColor(white: 0.55, alpha: 1)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
                .tint(.white)
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
    @State private var showPlayer = Demo.screen == "player"
    @State private var tab = RootView.startTab

    /// Экран, с которого начинает демо-режим; обычный запуск открывает главную.
    private static var startTab: Int {
        switch Demo.screen {
        case "search": return 1
        case "library", "likes", "settings": return 2
        default: return 0
        }
    }

    private func startPath(_ index: Int) -> [Route] {
        guard index == tab else { return [] }
        switch Demo.screen {
        case "likes": return [.likes]
        case "settings": return [.settings]
        case "album": return Demo.data.albums.first.map { [.album($0.id)] } ?? []
        case "artist": return Demo.data.artists.first.map { [.artist($0.id, $0.title)] } ?? []
        default: return []
        }
    }

    var body: some View {
        Group {
            if session.token == nil {
                LoginScreen()
            } else {
                tabs
            }
        }
        .alert("Tune", isPresented: errorShown) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(player.errorText ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { player.errorText != nil }, set: { if !$0 { player.errorText = nil } })
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            TabRoot(path: startPath(0)) { HomeScreen() }
                .tabItem { Label("Главная", systemImage: "house.fill") }
                .tag(0)
            TabRoot(path: startPath(1)) { SearchScreen() }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                .tag(1)
            TabRoot(path: startPath(2)) { LibraryScreen() }
                .tabItem { Label("Коллекция", systemImage: "heart.fill") }
                .tag(2)
        }
        .tint(Theme.accent)
        .environment(\.openPlayer, { showPlayer = true })
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerScreen()
        }
    }
}

/// Вкладка со своей историей переходов и мини-плеером над панелью вкладок.
struct TabRoot<Content: View>: View {
    @State private var path: [Route]
    private let content: Content

    init(path: [Route] = [], @ViewBuilder content: () -> Content) {
        _path = State(initialValue: path)
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                        .toolbarBackground(.hidden, for: .navigationBar)
                }
        }
        .tint(.white)
        .environment(\.navigate, { path.append($0) })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer()
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .likes: TrackListScreen(kind: .likes)
        case .downloads: TrackListScreen(kind: .downloads)
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
