import Foundation

/// Скачанные треки. Файлы лежат в Application Support/Tune/Tracks и играют без сети.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    struct Entry: Codable {
        var track: Track
        var file: String
        var bytes: Int64
        var date: Date
    }

    @Published private(set) var entries: [Entry] = []
    /// Ход загрузок: номер трека → доля от 0 до 1. Ждущие своей очереди — 0.
    @Published private(set) var active: [String: Double] = [:]
    @Published private(set) var failed: Set<String> = []

    private var files: [String: String] = [:]
    private var pending: [Track] = []
    private var running = 0
    private let parallel = 2

    var tracks: [Track] { entries.map(\.track) }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    private init() {
        let saved: [Entry] = Storage.load("downloads.json") ?? []
        // Запись без файла бесполезна: например, после восстановления из копии.
        entries = saved.filter { FileManager.default.fileExists(atPath: Storage.tracks.appendingPathComponent($0.file).path) }
        for entry in entries { files[entry.track.id] = entry.file }
    }

    func has(_ id: String) -> Bool {
        files[id] != nil
    }

    func fileURL(for id: String) -> URL? {
        files[id].map { Storage.tracks.appendingPathComponent($0) }
    }

    func isBusy(_ id: String) -> Bool {
        active[id] != nil
    }

    func download(_ track: Track) {
        download([track])
    }

    func download(_ list: [Track]) {
        for track in list where !has(track.id) && active[track.id] == nil && !(track.unavailable && !track.uncensored) {
            active[track.id] = 0
            failed.remove(track.id)
            pending.append(track)
        }
        pump()
    }

    func cancelAll() {
        for track in pending { active[track.id] = nil }
        pending.removeAll()
    }

    private func pump() {
        while running < parallel, !pending.isEmpty {
            let track = pending.removeFirst()
            running += 1
            Task {
                await fetch(track)
                running -= 1
                pump()
            }
        }
    }

    private func fetch(_ track: Track) async {
        do {
            let source = try await TrackFiles.source(for: track, quality: Settings.downloadQuality)
            let file = try await TrackFiles.download(id: track.id, from: source, to: Storage.tracks) { value in
                Task { @MainActor [weak self] in
                    // Экран перерисовывается не на каждый пакет, а раз в 4 %.
                    guard let self, let shown = self.active[track.id], value - shown >= 0.04 else { return }
                    self.active[track.id] = value
                }
            }
            await ImageLoader.shared.pin(track.cover)
            let bytes = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            entries.removeAll { $0.track.id == track.id }
            entries.insert(Entry(track: track, file: file.lastPathComponent, bytes: bytes, date: Date()), at: 0)
            files[track.id] = file.lastPathComponent
            save()
        } catch {
            failed.insert(track.id)
        }
        active[track.id] = nil
    }

    func remove(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.track.id == id }) else { return }
        let entry = entries.remove(at: index)
        files[id] = nil
        try? FileManager.default.removeItem(at: Storage.tracks.appendingPathComponent(entry.file))
        // Обложка могла быть общей с другим скачанным треком альбома.
        if !entries.contains(where: { $0.track.cover == entry.track.cover }) {
            ImageLoader.shared.unpin(entry.track.cover)
        }
        save()
    }

    func removeAll() {
        cancelAll()
        entries.removeAll()
        files.removeAll()
        Storage.clear(Storage.tracks)
        Storage.clear(Storage.covers)
        save()
    }

    private func save() {
        let snapshot = entries
        Task.detached(priority: .utility) { Storage.save(snapshot, "downloads.json") }
    }
}
