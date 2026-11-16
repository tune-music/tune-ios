import Foundation

@MainActor
final class Uploads {
    static let shared = Uploads()
    static let likesChanged = Notification.Name("tune.uploadedLikesChanged")

    private let storage = "pending-upload-likes.json"
    private var pending: [String: [String]] = Storage.load("pending-upload-likes.json") ?? [:]
    private var worker: Task<Void, Never>?
    private var busy = false

    private init() {}

    func add(_ files: [URL], to playlist: Playlist?) async {
        guard !busy, !files.isEmpty, let uid = Session.shared.profile?.uid else { return }
        let session = Session.shared
        busy = true
        defer { busy = false }
        do {
            let destination: Playlist
            if let playlist, playlist.owner == uid {
                destination = playlist
            } else {
                let lists = try await API.shared.playlists(uid: uid)
                guard session.profile?.uid == uid else { return }
                if let uploads = lists.first(where: { $0.title == "Загруженное" }) {
                    destination = uploads
                } else if let created = await session.createPlaylist("Загруженное") {
                    destination = created
                } else {
                    throw APIError.server("Не удалось открыть плейлист «Загруженное»")
                }
            }
            var sent = 0
            var failure: String?
            for (offset, file) in files.enumerated() {
                guard session.profile?.uid == uid, !Task.isCancelled else { return }
                session.show("Загружаем \(offset + 1) из \(files.count)")
                do {
                    let id = try await API.shared.uploadTrack(file, to: destination)
                    sent += 1
                    if playlist == nil {
                        pending[uid, default: []].append(id)
                        save()
                    }
                } catch {
                    failure = error.localizedDescription
                    if failure == "Превышен лимит по количеству загруженных треков" { break }
                }
            }
            if sent > 0, playlist == nil { resume() }
            if let failure {
                session.show("Загружено \(sent) из \(files.count). \(failure)")
            } else {
                session.show(playlist == nil
                    ? "Файлы загружены. Лайки появятся после обработки"
                    : "Файлы загружены. Яндекс обрабатывает треки")
            }
        } catch {
            if !Task.isCancelled { session.show(error.localizedDescription) }
        }
    }

    func resume() {
        guard worker == nil, !Connectivity.shared.offline, let uid = Session.shared.profile?.uid,
              pending[uid]?.isEmpty == false else { return }
        worker = Task {
            defer { worker = nil }
            for _ in 0..<25 {
                guard Session.shared.profile?.uid == uid, !Connectivity.shared.offline,
                      let ids = pending[uid], !ids.isEmpty else { return }
                do {
                    let ready = try await API.shared.readyUploads(Array(ids.prefix(100)))
                    var liked = Set<String>()
                    for id in ready {
                        guard Session.shared.profile?.uid == uid else { return }
                        do {
                            try await API.shared.setLiked(uid: uid, track: id, liked: true)
                            liked.insert(id)
                            pending[uid]?.removeAll { $0 == id }
                            save()
                        } catch {
                            if Task.isCancelled { return }
                        }
                    }
                    if !liked.isEmpty, Session.shared.profile?.uid == uid {
                        Session.shared.registerUploadedLikes(liked)
                        NotificationCenter.default.post(name: Self.likesChanged, object: nil)
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func save() { Storage.save(pending, storage) }
}
