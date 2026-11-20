import Foundation
import Network

/// Скачанные треки. Файлы лежат в Application Support/Tune/Tracks и играют без сети.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    struct Entry: Codable, Equatable {
        var track: Track
        var file: String
        var bytes: Int64
        var date: Date
        var version: TrackFiles.Version? = nil
    }

    /// То, что переживает перезапуск: недокачанное и то, что скачать не вышло.
    private struct Pending: Codable {
        var queue: [Track]
        var failed: [Track]
    }

    @Published private(set) var entries: [Entry] = []
    /// Ход загрузок: номер трека → доля от 0 до 1. Ждущие своей очереди — 0.
    @Published private(set) var active: [String: Double] = [:]
    /// Очередь по порядку: и те, что качаются сейчас, и ждущие.
    @Published private(set) var queue: [Track] = []
    /// Треки, которые скачать не удалось: их можно повторить.
    @Published private(set) var failed: [Track] = []
    @Published private(set) var paused = false
    /// Сеть платная (сотовая или раздача с телефона).
    @Published private(set) var cellular = false

    private var files: [String: String] = [:]
    private var running: Set<String> = []
    private let parallel = 2
    private var pendingAssets: Set<String> = []
    private var checkedLyrics: [String: String] = [:]
    private var activeAssets: Set<String> = []
    private var deferredAssets: Set<String> = []
    private let assetParallel = 2
    private let monitor = NWPathMonitor()

    var tracks: [Track] { entries.map(\.track) }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    /// Загрузки ждут Wi-Fi: так выбрано в настройках.
    var holding: Bool { Settings.wifiOnly && cellular }

    private init() {
        let saved: [Entry] = Storage.load("downloads.json") ?? []
        // Запись без файла бесполезна: например, после восстановления из копии.
        entries = saved.filter { FileManager.default.fileExists(atPath: Storage.tracks.appendingPathComponent($0.file).path) }
        for entry in entries { files[entry.track.id] = entry.file }

        if Demo.on {
            if Demo.screen == "downloads" {
                let sample = Demo.data.tracks
                queue = Array(sample.prefix(4))
                failed = Array(sample.dropFirst(4).prefix(2))
                for (index, track) in queue.enumerated() { active[track.id] = [0.62, 0.18][safe: index] ?? 0 }
                running = Set(queue.prefix(2).map(\.id))
            }
            return
        }

        if let pending = Storage.load("download-queue.json", as: Pending.self) {
            queue = pending.queue.filter { files[$0.id] == nil }
            failed = pending.failed.filter { files[$0.id] == nil }
            for track in queue { active[track.id] = 0 }
        }
        pendingAssets = Set(Storage.load("download-assets.json", as: [String].self) ?? [])
        checkedLyrics = Storage.load("lyrics-checked.json", as: [String: String].self) ?? [:]
        let validIDs = Set(entries.map(\.track.id))
        let prunedPending = pendingAssets.intersection(validIDs)
        if prunedPending != pendingAssets {
            pendingAssets = prunedPending
            saveAssets()
        }
        BackgroundFetcher.shared.start()
        monitor.pathUpdateHandler = { path in
            let expensive = path.isExpensive
            Task { @MainActor in
                let downloads = Downloads.shared
                if downloads.cellular != expensive { downloads.cellular = expensive }
                downloads.pump()
                downloads.resumeAssets()
            }
        }
        monitor.start(queue: DispatchQueue(label: "tune.network"))
        Task { @MainActor [weak self] in
            self?.resumeAssets()
        }
    }

    func has(_ id: String) -> Bool {
        files[id] != nil
    }

    func fileURL(for id: String) -> URL? {
        files[id].map { Storage.tracks.appendingPathComponent($0) }
    }

    func version(for id: String) -> TrackFiles.Version? {
        guard let entry = entries.first(where: { $0.track.id == id }) else { return nil }
        return entry.version ?? (entry.track.uncensored ? .uncensored : .yandex)
    }

    func isBusy(_ id: String) -> Bool {
        active[id] != nil
    }

    /// Качается прямо сейчас, а не ждёт очереди.
    func isRunning(_ id: String) -> Bool {
        running.contains(id)
    }

    func download(_ track: Track) {
        download([track])
    }

    func download(_ list: [Track]) {
        var added = false
        for track in list where !has(track.id) && active[track.id] == nil && !(track.unavailable && !track.uncensored) {
            active[track.id] = 0
            failed.removeAll { $0.id == track.id }
            queue.append(track)
            added = true
        }
        guard added else { return }
        savePending()
        pump()
    }

    /// Новые лайки скачиваются сами, если это включено в настройках.
    func auto(_ list: [Track]) {
        guard Settings.autoLikes, !Demo.on else { return }
        download(list)
    }

    /// Плейлист помечен «скачивать автоматически»: всё новое в нём скачивается само.
    func autoPlaylist(_ playlist: Playlist, _ tracks: [Track]) {
        guard !Demo.on, Settings.autoPlaylists.contains(playlist.id) else { return }
        download(tracks)
    }

    /// После запуска: проверяет помеченные плейлисты и докачивает то, чего ещё нет.
    func syncPlaylists() async {
        let wanted = Set(Settings.autoPlaylists)
        guard !Demo.on, !wanted.isEmpty else { return }
        let session = Session.shared
        for playlist in session.playlists + session.likedPlaylists where wanted.contains(playlist.id) {
            if let tracks = try? await API.shared.playlistTracks(playlist) { download(tracks) }
        }
    }

    /// Настройки загрузок поменялись: пересчитать, можно ли качать.
    func settingsChanged() {
        objectWillChange.send()
        pump()
        resumeAssets()
    }

    /// Проверяет обложки и тексты для скачанных треков (включая старые загрузки и смену настроек).
    func resumeAssets() {
        guard !Demo.on, !Connectivity.shared.offline, !holding else { return }
        deferredAssets.removeAll()
        let key = ExternalLyrics.settingsKey
        var changed = false
        for entry in entries {
            let id = entry.track.id
            if !API.hasSavedLyrics(for: entry.track), checkedLyrics[id] != key {
                if pendingAssets.insert(id).inserted { changed = true }
            }
        }
        if changed { saveAssets() }
        pumpAssets()
    }

    func pause() {
        paused = true
    }

    func resume() {
        paused = false
        pump()
    }

    /// Убирает из очереди всё, что ещё не начало качаться.
    func cancelAll() {
        for track in queue where !running.contains(track.id) { active[track.id] = nil }
        queue.removeAll { !running.contains($0.id) }
        paused = false
        savePending()
    }

    func cancel(_ id: String) {
        guard !running.contains(id) else { return }
        queue.removeAll { $0.id == id }
        active[id] = nil
        savePending()
    }

    func retryFailed() {
        let list = failed
        failed = []
        download(list)
    }

    func forgetFailed() {
        failed = []
        savePending()
    }

    private func pump() {
        guard !Demo.on, !paused, !holding else { return }
        while running.count < parallel, let track = queue.first(where: { !running.contains($0.id) }) {
            running.insert(track.id)
            Task {
                await fetch(track)
                running.remove(track.id)
                queue.removeAll { $0.id == track.id }
                active[track.id] = nil
                savePending()
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
            entries.insert(Entry(track: track, file: file.lastPathComponent, bytes: bytes, date: Date(), version: source.version), at: 0)
            files[track.id] = file.lastPathComponent
            pendingAssets.insert(track.id)
            deferredAssets.remove(track.id)
            checkedLyrics.removeValue(forKey: track.id)
            save()
            saveAssets()
            pumpAssets()
        } catch {
            Log.shared.add("загрузка: \(track.id): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            if !failed.contains(where: { $0.id == track.id }) { failed.append(track) }
        }
    }

    private func pumpAssets() {
        guard !Demo.on, !Connectivity.shared.offline, !holding else { return }
        while activeAssets.count < assetParallel,
              let entry = entries.first(where: {
                  pendingAssets.contains($0.track.id) &&
                  !activeAssets.contains($0.track.id) &&
                  !deferredAssets.contains($0.track.id)
              }) {
            let track = entry.track
            let key = ExternalLyrics.settingsKey
            activeAssets.insert(track.id)
            Task(priority: .utility) { [weak self] in
                async let cover: Void = ImageLoader.shared.pin(track.cover)
                let done = await API.shared.prefetchLyrics(for: track)
                await cover
                await MainActor.run {
                    guard let self else { return }
                    self.activeAssets.remove(track.id)
                    if done {
                        self.pendingAssets.remove(track.id)
                        self.deferredAssets.remove(track.id)
                        if self.has(track.id) {
                            self.checkedLyrics[track.id] = key
                        }
                        self.saveAssets()
                    } else {
                        self.deferredAssets.insert(track.id)
                    }
                    self.pumpAssets()
                }
            }
        }
    }

    func remove(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.track.id == id }) else { return }
        let entry = entries.remove(at: index)
        files[id] = nil
        pendingAssets.remove(id)
        deferredAssets.remove(id)
        checkedLyrics.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: Storage.tracks.appendingPathComponent(entry.file))
        // Обложка могла быть общей с другим скачанным треком альбома.
        if !entries.contains(where: { $0.track.cover == entry.track.cover }) {
            ImageLoader.shared.unpin(entry.track.cover)
        }
        save()
        saveAssets()
    }

    func removeAll() {
        cancelAll()
        failed = []
        entries.removeAll()
        files.removeAll()
        pendingAssets.removeAll()
        deferredAssets.removeAll()
        checkedLyrics.removeAll()
        Storage.clear(Storage.tracks)
        Storage.clear(Storage.covers)
        save()
        savePending()
        saveAssets()
    }

    func updateUploadedMetadata(id: String, title: String, artist: String) {
        guard let index = entries.firstIndex(where: { $0.track.id == id }) else { return }
        entries[index].track = entries[index].track.withUploadedMetadata(title: title, artist: artist)
        save()
    }

    private func save() {
        let snapshot = entries
        Task.detached(priority: .utility) { Storage.save(snapshot, "downloads.json") }
    }

    private func savePending() {
        if Demo.on { return }
        let snapshot = Pending(queue: queue, failed: failed)
        Task.detached(priority: .utility) { Storage.save(snapshot, "download-queue.json") }
    }

    private func saveAssets() {
        if Demo.on { return }
        let pendingSnapshot = Array(pendingAssets)
        let checkedSnapshot = checkedLyrics
        Task.detached(priority: .utility) {
            Storage.save(pendingSnapshot, "download-assets.json")
            Storage.save(checkedSnapshot, "lyrics-checked.json")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
