import Foundation
import WebKit

/// Аккаунт и коллекция. Последнее состояние хранится на диске: приложение открывается
/// и без сети.
@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    private struct Saved: Codable {
        var profile: Profile?
        var liked: [String]
        var playlists: [Playlist]
    }

    @Published private(set) var token: String?
    @Published private(set) var profile: Profile?
    @Published private(set) var likedIds: [String] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var offline = false
    private var likedSet: Set<String> = []
    private var refreshTask: Task<Void, Never>?

    private init() {
        token = Demo.on ? "demo" : TokenStore.token
        if Demo.on { return }
        if let saved: Saved = Storage.load("session.json") {
            profile = saved.profile
            likedIds = saved.liked
            likedSet = Set(saved.liked)
            playlists = saved.playlists
        }
    }

    func isLiked(_ id: String) -> Bool {
        likedSet.contains(id)
    }

    func login(token: String) {
        TokenStore.set(token)
        self.token = token
        Task { await refresh() }
    }

    func logout() {
        Player.shared.stop()
        TokenStore.set(nil)
        token = nil
        profile = nil
        likedIds = []
        likedSet = []
        playlists = []
        Storage.remove("session.json")
        Storage.remove("likes-tracks.json")
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// Профиль, лайки и плейлисты с сервера. Без сети остаётся то, что было.
    func refresh() async {
        guard token != nil else { return }
        if let task = refreshTask {
            await task.value
            return
        }
        let task = Task { await load() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func load() async {
        do {
            let profile = try await API.shared.profile()
            self.profile = profile
            offline = false
            async let likedTask = API.shared.likedIds(uid: profile.uid)
            async let listsTask = API.shared.playlists(uid: profile.uid)
            if let ids = try? await likedTask { setLiked(ids) }
            if let lists = try? await listsTask { playlists = lists }
            save()
        } catch APIError.needLogin {
            logout()
        } catch {
            offline = true
        }
    }

    func setLiked(_ ids: [String]) {
        guard ids != likedIds else { return }
        likedIds = ids
        likedSet = Set(ids)
        save()
    }

    func toggleLike(_ track: Track) {
        guard let uid = profile?.uid else { return }
        let liked = !isLiked(track.id)
        apply(track.id, liked)
        Task {
            do {
                try await API.shared.setLiked(uid: uid, track: track.id, liked: liked)
                save()
            } catch {
                apply(track.id, !liked)
                Player.shared.errorText = "Не удалось сохранить лайк"
            }
        }
    }

    private func apply(_ id: String, _ liked: Bool) {
        if liked {
            guard !likedSet.contains(id) else { return }
            likedSet.insert(id)
            likedIds.insert(id, at: 0)
        } else {
            likedSet.remove(id)
            likedIds.removeAll { $0 == id }
        }
    }

    private func save() {
        if Demo.on { return }
        let saved = Saved(profile: profile, liked: likedIds, playlists: playlists)
        Task.detached(priority: .utility) { Storage.save(saved, "session.json") }
    }
}
