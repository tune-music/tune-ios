import SwiftUI

@main
struct TuneApp: App {
    @StateObject private var session = Session.shared
    @StateObject private var player = Player.shared
    @StateObject private var downloads = Downloads.shared

    init() {
        Uncensor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(player)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
                .tint(.accentColor)
                .task { await session.refresh() }
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
    case settings
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
    @State private var showPlayer = false

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
        TabView {
            TabRoot { HomeScreen() }
                .tabItem { Label("Главная", systemImage: "house.fill") }
            TabRoot { SearchScreen() }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
            TabRoot { LibraryScreen() }
                .tabItem { Label("Коллекция", systemImage: "heart.fill") }
        }
        .environment(\.openPlayer, { showPlayer = true })
        .sheet(isPresented: $showPlayer) {
            PlayerScreen()
        }
    }
}

/// Вкладка со своей историей переходов и мини-плеером над панелью вкладок.
struct TabRoot<Content: View>: View {
    @State private var path: [Route] = []
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .likes: TrackListScreen(kind: .likes)
                    case .downloads: TrackListScreen(kind: .downloads)
                    case .playlist(let playlist): TrackListScreen(kind: .playlist(playlist))
                    case .album(let id): TrackListScreen(kind: .album(id))
                    case .artistTracks(let id, let name): TrackListScreen(kind: .artist(id, name))
                    case .artist(let id, let name): ArtistScreen(id: id, name: name)
                    case .settings: SettingsScreen()
                    }
                }
        }
        .environment(\.navigate, { path.append($0) })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayer()
        }
    }
}
