import Foundation
import UIKit
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
        var likedPlaylists: [Playlist]?
        var albums: [String]?
        var artists: [String]?
        var disliked: [String]?
    }

    @Published private(set) var token: String?
    @Published private(set) var profile: Profile?
    @Published private(set) var likedIds: [String] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var likedPlaylists: [Playlist] = []
    @Published private(set) var likedAlbums: Set<String> = []
    @Published private(set) var likedArtists: Set<String> = []
    @Published private(set) var disliked: Set<String> = []
    @Published private(set) var offline = false
    /// Короткое сообщение поверх экрана: «Добавлено в плейлист».
    @Published var toast: String?
    private var likedSet: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private init() {
        token = Demo.on ? "demo" : TokenStore.token
        if Demo.on { return }
        if let saved: Saved = Storage.load("session.json") {
            profile = saved.profile
            likedIds = saved.liked
            likedSet = Set(saved.liked)
            playlists = saved.playlists
            likedPlaylists = saved.likedPlaylists ?? []
            likedAlbums = Set(saved.albums ?? [])
            likedArtists = Set(saved.artists ?? [])
            disliked = Set(saved.disliked ?? [])
        }
    }

    func isLiked(_ id: String) -> Bool {
        likedSet.contains(id)
    }

    /// Свой плейлист можно править, чужой — только добавить в коллекцию.
    func isOwn(_ playlist: Playlist) -> Bool {
        playlist.owner == profile?.uid
    }

    func isLiked(_ playlist: Playlist) -> Bool {
        likedPlaylists.contains { $0.id == playlist.id }
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func fail(_ text: String) {
        Player.shared.errorText = text
    }

    // MARK: - Вход

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
        likedPlaylists = []
        likedAlbums = []
        likedArtists = []
        disliked = []
        Storage.remove("session.json")
        Storage.remove("likes-tracks.json")
        Storage.remove("home.json")
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
            let uid = profile.uid
            async let likedTask = API.shared.likedIds(uid: uid)
            async let listsTask = API.shared.playlists(uid: uid)
            async let likedListsTask = API.shared.likedPlaylists(uid: uid)
            async let albumsTask = API.shared.likedAlbumIds(uid: uid)
            async let artistsTask = API.shared.likedArtistIds(uid: uid)
            async let dislikedTask = API.shared.dislikedIds(uid: uid)
            if let ids = try? await likedTask { setLiked(ids) }
            if let lists = try? await listsTask { playlists = lists }
            if let lists = try? await likedListsTask { likedPlaylists = lists }
            if let ids = try? await albumsTask { likedAlbums = Set(ids) }
            if let ids = try? await artistsTask { likedArtists = Set(ids) }
            if let ids = try? await dislikedTask { disliked = Set(ids) }
            save()
        } catch APIError.needLogin {
            logout()
        } catch {
            offline = true
        }
    }

    // MARK: - Лайки и дизлайки

    func setLiked(_ ids: [String]) {
        guard ids != likedIds else { return }
        likedIds = ids
        likedSet = Set(ids)
        save()
    }

    func toggleLike(_ track: Track) {
        guard let uid = profile?.uid else { return }
        let liked = !isLiked(track.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        apply(track.id, liked)
        if liked {
            disliked.remove(track.id)
            Downloads.shared.auto([track])
        }
        Task {
            do {
                try await API.shared.setLiked(uid: uid, track: track.id, liked: liked)
                save()
            } catch {
                apply(track.id, !liked)
                fail("Не удалось сохранить лайк")
            }
        }
    }

    /// Возвращает true, если трек теперь с дизлайком.
    @discardableResult
    func toggleDislike(_ track: Track) -> Bool {
        guard let uid = profile?.uid else { return false }
        let now = !disliked.contains(track.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if now {
            disliked.insert(track.id)
            apply(track.id, false)
            show("Больше не порекомендуем")
        } else {
            disliked.remove(track.id)
        }
        Task {
            do {
                try await API.shared.setDisliked(uid: uid, track: track.id, disliked: now)
                save()
            } catch {
                if now { disliked.remove(track.id) } else { disliked.insert(track.id) }
                fail("Не удалось сохранить дизлайк")
            }
        }
        return now
    }

    private func apply(_ id: String, _ liked: Bool) {
        if liked {
            guard !likedSet.contains(id) else { return }
            likedSet.insert(id)
            likedIds.insert(id, at: 0)
        } else {
            guard likedSet.contains(id) else { return }
            likedSet.remove(id)
            likedIds.removeAll { $0 == id }
        }
    }

    func toggleAlbum(_ id: String) {
        guard let uid = profile?.uid else { return }
        let liked = !likedAlbums.contains(id)
        if liked { likedAlbums.insert(id) } else { likedAlbums.remove(id) }
        show(liked ? "Альбом добавлен в коллекцию" : "Альбом убран из коллекции")
        Task {
            do {
                try await API.shared.setLiked(uid: uid, kind: "albums", param: "album-id", id: id, liked: liked)
                save()
            } catch {
                if liked { likedAlbums.remove(id) } else { likedAlbums.insert(id) }
                fail("Не удалось изменить коллекцию")
            }
        }
    }

    func toggleArtist(_ id: String) {
        guard let uid = profile?.uid else { return }
        let liked = !likedArtists.contains(id)
        if liked { likedArtists.insert(id) } else { likedArtists.remove(id) }
        show(liked ? "Исполнитель добавлен в коллекцию" : "Исполнитель убран из коллекции")
        Task {
            do {
                try await API.shared.setLiked(uid: uid, kind: "artists", param: "artist-id", id: id, liked: liked)
                save()
            } catch {
                if liked { likedArtists.remove(id) } else { likedArtists.insert(id) }
                fail("Не удалось изменить коллекцию")
            }
        }
    }

    func togglePlaylist(_ playlist: Playlist) {
        guard let uid = profile?.uid else { return }
        let liked = !isLiked(playlist)
        if liked { likedPlaylists.insert(playlist, at: 0) } else { likedPlaylists.removeAll { $0.id == playlist.id } }
        show(liked ? "Плейлист добавлен в коллекцию" : "Плейлист убран из коллекции")
        Task {
            do {
                try await API.shared.setLiked(uid: uid, playlist: playlist, liked: liked)
                save()
            } catch {
                if liked { likedPlaylists.removeAll { $0.id == playlist.id } } else { likedPlaylists.insert(playlist, at: 0) }
                fail("Не удалось изменить коллекцию")
            }
        }
    }

    // MARK: - Свои плейлисты

    func createPlaylist(_ title: String) async -> Playlist? {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard let uid = profile?.uid, !name.isEmpty else { return nil }
        do {
            let playlist = try await API.shared.createPlaylist(uid: uid, title: name)
            playlists.insert(playlist, at: 0)
            save()
            return playlist
        } catch {
            fail("Не удалось создать плейлист")
            return nil
        }
    }

    func rename(_ playlist: Playlist, to title: String) async -> Bool {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard let uid = profile?.uid, !name.isEmpty else { return false }
        do {
            try await API.shared.renamePlaylist(uid: uid, kind: playlist.kind, title: name)
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[index].title = name }
            save()
            return true
        } catch {
            fail("Не удалось переименовать плейлист")
            return false
        }
    }

    func delete(_ playlist: Playlist) async -> Bool {
        guard let uid = profile?.uid else { return false }
        do {
            try await API.shared.deletePlaylist(uid: uid, kind: playlist.kind)
            playlists.removeAll { $0.id == playlist.id }
            save()
            return true
        } catch {
            fail("Не удалось удалить плейлист")
            return false
        }
    }

    func add(_ track: Track, to playlist: Playlist) async {
        await add([track], to: playlist)
    }

    func add(_ tracks: [Track], to playlist: Playlist) async {
        guard let uid = profile?.uid, !tracks.isEmpty else { return }
        do {
            try await API.shared.addToPlaylist(uid: uid, kind: playlist.kind, tracks: tracks)
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[index].count += tracks.count }
            show(tracks.count == 1 ? "Добавлено в «\(playlist.title)»" : "В «\(playlist.title)» добавлено: \(plural(tracks.count, "трек", "трека", "треков"))")
            save()
        } catch {
            fail("Не удалось добавить в плейлист")
        }
    }

    /// Переставляет трек в своём плейлисте: перед треком `before` или в конец.
    func move(_ track: Track, in playlist: Playlist, before: String?) async -> Bool {
        guard let uid = profile?.uid else { return false }
        do {
            try await API.shared.moveInPlaylist(uid: uid, kind: playlist.kind, track: track, before: before)
            return true
        } catch {
            fail("Не удалось переставить трек")
            return false
        }
    }

    func remove(_ track: Track, from playlist: Playlist) async -> Bool {
        guard let uid = profile?.uid else { return false }
        do {
            try await API.shared.removeFromPlaylist(uid: uid, kind: playlist.kind, track: track)
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }), playlists[index].count > 0 { playlists[index].count -= 1 }
            save()
            return true
        } catch {
            fail("Не удалось убрать трек из плейлиста")
            return false
        }
    }

    private func save() {
        if Demo.on { return }
        let saved = Saved(
            profile: profile, liked: likedIds, playlists: playlists, likedPlaylists: likedPlaylists,
            albums: Array(likedAlbums), artists: Array(likedArtists), disliked: Array(disliked))
        Task.detached(priority: .utility) { Storage.save(saved, "session.json") }
    }
}

/// Переходы между страницами: у каждой вкладки своя история. Общий объект нужен, чтобы
/// открыть альбом или исполнителя из плеера, который лежит поверх вкладок.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()

    @Published var tab = 0
    @Published var paths: [[Route]] = [[], [], []]

    private init() {
        // Демо-режим сразу открывает нужный экран.
        guard Demo.on else { return }
        let data = Demo.data
        switch Demo.screen {
        case "search": tab = 1
        case "library": tab = 2
        case "likes", "filter": tab = 2; paths[2] = [.likes]
        case "history": tab = 2; paths[2] = [.history]
        case "downloads": tab = 2; paths[2] = [.downloads]
        case "stats": tab = 2; paths[2] = [.stats]
        case "settings": tab = 2; paths[2] = [.settings]
        case "shelf": paths[0] = Demo.home.first.map { [.block($0)] } ?? []
        case "playlist", "select": tab = 2; paths[2] = data.playlists.first.map { [.playlist($0)] } ?? []
        case "album", "albumscroll": paths[0] = data.albums.first.map { [.album($0.id)] } ?? []
        case "artist": paths[0] = data.artists.first.map { [.artist($0.id, $0.title)] } ?? []
        default: break
        }
    }

    func push(_ route: Route) {
        paths[tab].append(route)
    }
}
