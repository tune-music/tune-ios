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
    @Published private(set) var blockedArtists = Set(UserDefaults.standard.stringArray(forKey: "blockedArtists") ?? [])
    @Published private(set) var offline = false
    /// Короткое сообщение поверх экрана: «Добавлено в плейлист».
    @Published var toast: String?
    /// Все аккаунты, в которые входили на этом устройстве.
    @Published private(set) var accounts: [Account] = []
    /// Открыт вход для ещё одного аккаунта.
    @Published var adding = false
    /// Растёт при смене аккаунта: по нему страницы строятся заново.
    @Published private(set) var epoch = 0
    private var likedSet: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    private init() {
        token = Demo.on ? "demo" : TokenStore.token
        if Demo.on {
            accounts = [
                Account(uid: "demo", name: "Демо", login: "demo", token: ""),
                Account(uid: "demo2", name: "Второй аккаунт", login: "second", token: ""),
            ]
            return
        }
        accounts = AccountStore.load()
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
        // Вход вторым аккаунтом: данные прежнего убираются с экрана.
        let switching = self.token != nil
        if switching { reset() }
        TokenStore.set(token)
        self.token = token
        adding = false
        if switching { epoch += 1 }
        Task { await refresh() }
    }

    /// Вход ещё одним аккаунтом. Страница Яндекса помнит прежний вход, поэтому её данные стираются.
    func addAccount() {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        adding = true
    }

    func switchTo(_ account: Account) {
        guard account.token != token, !account.token.isEmpty else { return }
        reset()
        TokenStore.set(account.token)
        token = account.token
        epoch += 1
        show("Аккаунт: " + (account.name.isEmpty ? account.login : account.name))
        Task { await refresh() }
    }

    /// Выход из текущего аккаунта. Если есть другие — открывается следующий.
    func logout() {
        let gone = token
        reset()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        accounts.removeAll { $0.token == gone }
        AccountStore.save(accounts)
        if let next = accounts.first {
            TokenStore.set(next.token)
            token = next.token
            epoch += 1
            Task { await refresh() }
        } else {
            TokenStore.set(nil)
            token = nil
        }
    }

    /// Убирает всё, что относится к текущему аккаунту. Скачанная музыка остаётся.
    private func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        Player.shared.stop()
        profile = nil
        likedIds = []
        likedSet = []
        playlists = []
        likedPlaylists = []
        likedAlbums = []
        likedArtists = []
        disliked = []
        for name in ["session.json", "likes-tracks.json", "home.json", "liked-albums.json", "liked-artists.json"] {
            Storage.remove(name)
        }
        Storage.clear(Storage.lists)
        Router.shared.paths = [[], [], []]
    }

    /// Запоминает аккаунт с его токеном, когда Яндекс подтвердил вход.
    private func remember(_ profile: Profile) {
        guard !Demo.on, let token else { return }
        let account = Account(uid: profile.uid, name: profile.name, login: profile.login, token: token)
        var list = accounts
        if let index = list.firstIndex(where: { $0.uid == account.uid }) {
            list[index] = account
        } else {
            list.append(account)
        }
        guard list != accounts else { return }
        accounts = list
        AccountStore.save(list)
    }

    /// Профиль, лайки и плейлисты с сервера. Без сети остаётся то, что было.
    func refresh() async {
        guard token != nil else { return }
        if let task = refreshTask {
            await task.value
            return
        }
        let requestedToken = token
        let task = Task { await load() }
        refreshTask = task
        await task.value
        if token == requestedToken { refreshTask = nil }
    }

    private func load() async {
        let requestedToken = token
        do {
            let profile = try await API.shared.profile()
            guard !Task.isCancelled, token == requestedToken else { return }
            self.profile = profile
            remember(profile)
            offline = false
            let uid = profile.uid
            async let likedTask = API.shared.likedIds(uid: uid)
            async let listsTask = API.shared.playlists(uid: uid)
            async let likedListsTask = API.shared.likedPlaylists(uid: uid)
            async let albumsTask = API.shared.likedAlbumIds(uid: uid)
            async let artistsTask = API.shared.likedArtistIds(uid: uid)
            async let dislikedTask = API.shared.dislikedIds(uid: uid)
            let snapshot = (try? await likedTask, try? await listsTask, try? await likedListsTask,
                            try? await albumsTask, try? await artistsTask, try? await dislikedTask)
            guard !Task.isCancelled, token == requestedToken else { return }
            if let ids = snapshot.0 { setLiked(ids) }
            if let lists = snapshot.1, lists != playlists { playlists = lists }
            if let lists = snapshot.2, lists != likedPlaylists { likedPlaylists = lists }
            if let ids = snapshot.3, Set(ids) != likedAlbums { likedAlbums = Set(ids) }
            if let ids = snapshot.4, Set(ids) != likedArtists { likedArtists = Set(ids) }
            if let ids = snapshot.5, Set(ids) != disliked { disliked = Set(ids) }
            save()
        } catch APIError.needLogin {
            if !Task.isCancelled, token == requestedToken { logout() }
        } catch {
            if !Task.isCancelled, token == requestedToken { offline = true }
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
        if Player.shared.isWave, Player.shared.current?.id == track.id {
            WaveTaste.shared.react(liked ? "like" : "unlike", track: track, played: nil)
        }
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
        if Player.shared.isWave, Player.shared.current?.id == track.id {
            WaveTaste.shared.react(now ? "dislike" : "undislike", track: track, played: nil)
        }
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

    /// Исполнитель, которого попросили не рекомендовать. Список хранится на устройстве.
    func isBlocked(_ artist: String) -> Bool {
        blockedArtists.contains(artist)
    }

    func toggleBlocked(_ artist: ArtistRef) {
        guard let uid = profile?.uid, !artist.id.isEmpty else { return }
        let blocked = !blockedArtists.contains(artist.id)
        if blocked { blockedArtists.insert(artist.id) } else { blockedArtists.remove(artist.id) }
        UserDefaults.standard.set(Array(blockedArtists), forKey: "blockedArtists")
        show(blocked ? "\(artist.name) больше не будет в рекомендациях" : "\(artist.name) снова в рекомендациях")
        Task {
            do {
                try await API.shared.setBlocked(uid: uid, artist: artist.id, blocked: blocked)
            } catch {
                if blocked { blockedArtists.remove(artist.id) } else { blockedArtists.insert(artist.id) }
                UserDefaults.standard.set(Array(blockedArtists), forKey: "blockedArtists")
                fail("Не удалось сохранить")
            }
        }
    }

    func clearBlocked(_ id: String) {
        blockedArtists.remove(id)
        UserDefaults.standard.set(Array(blockedArtists), forKey: "blockedArtists")
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
        case "search", "find": tab = 1
        case "library": tab = 2
        case "likes", "filter": tab = 2; paths[2] = [.likes]
        case "history": tab = 2; paths[2] = [.history]
        case "downloads": tab = 2; paths[2] = [.downloads]
        case "stats": tab = 2; paths[2] = [.stats]
        case "stations": paths[0] = [.stations]
        case "settings": tab = 2; paths[2] = [.settings]
        case "changes": tab = 2; paths[2] = [.changes]
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
