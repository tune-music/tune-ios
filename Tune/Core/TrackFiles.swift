import Foundation

/// Откуда брать файл трека.
struct TrackSource {
    /// Ссылки по очереди: вторая — зеркало первой.
    var urls: [URL]
    var key: String?
    /// Файл надо сначала скачать: он зашифрован или сервер отдаёт его не как аудио.
    var needsFile: Bool
    var codec = "mp3"

    /// Тип содержимого для плеера: сервер Яндекса отдаёт поток как application/octet-stream,
    /// и без подсказки AVPlayer его не играет.
    var mime: String {
        switch codec {
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "aac", "he-aac": return "audio/aac"
        default: return "audio/mp4"
        }
    }
}

enum TrackFiles {
    /// Версия без цензуры из списка, иначе файл Яндекса.
    static func source(for track: Track, quality: String) async throws -> TrackSource {
        let uncensored = Uncensor.shared.files(for: track.id)
        if !uncensored.isEmpty {
            return TrackSource(urls: uncensored, key: nil, needsFile: true)
        }
        do {
            let info = try await API.shared.fileInfo(track: track.id, quality: quality, transport: "raw")
            if let url = URL(string: info.url) {
                return TrackSource(urls: [url], key: info.key, needsFile: info.key != nil, codec: info.codec)
            }
        } catch let error as APIError where error.isNetwork {
            throw error
        } catch APIError.needLogin {
            throw APIError.needLogin
        } catch {
            // Обычный файл не дали — просим зашифрованный, как официальный клиент.
        }
        let info = try await API.shared.fileInfo(track: track.id, quality: quality, transport: "encraw")
        guard let url = URL(string: info.url) else { throw APIError.server("Яндекс не дал файл трека") }
        return TrackSource(urls: [url], key: info.key, needsFile: true, codec: info.codec)
    }

    /// Скачивает файл в папку и возвращает его путь: имя — номер трека, расширение — по содержимому.
    static func download(id: String, from source: TrackSource, to directory: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> URL {
        var last: Error = TuneError("Не удалось получить файл трека")
        for url in source.urls {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 60
                // Скачивание «насовсем» идёт через фоновую сессию: оно продолжается и при
                // свёрнутом приложении. Файлы для немедленной игры качаются как раньше.
                let keeps = directory == Storage.tracks
                if keeps { request.allowsCellularAccess = !Settings.wifiOnly }
                let (temp, response) = try await fetch(request, background: keeps, progress: progress)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    try? FileManager.default.removeItem(at: temp)
                    throw TuneError("Сервер ответил \(status)")
                }
                var file = temp
                if let key = source.key {
                    let plain = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try AESCTR.decrypt(file: temp, to: plain, keyHex: key)
                    try? FileManager.default.removeItem(at: temp)
                    file = plain
                }
                guard let ext = format(of: file) else {
                    try? FileManager.default.removeItem(at: file)
                    throw TuneError("Файл трека не похож на аудио")
                }
                remove(id: id, in: directory)
                let target = directory.appendingPathComponent("\(id).\(ext)")
                try FileManager.default.moveItem(at: file, to: target)
                return target
            } catch {
                last = error
                if Task.isCancelled { break }
            }
        }
        throw last
    }

    private static func fetch(_ request: URLRequest, background: Bool, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        if background {
            do {
                return try await BackgroundFetcher.shared.download(request, progress: progress)
            } catch {
                // Фоновая сессия не справилась — пробуем обычную, как раньше.
                if Task.isCancelled { throw error }
            }
        }
        let watcher = ProgressWatcher(progress)
        return try await URLSession.shared.download(for: request, delegate: watcher)
    }

    /// Уже скачанный файл трека в папке.
    static func existing(id: String, in directory: URL) -> URL? {
        for ext in ["mp3", "m4a", "flac", "aac"] {
            let url = directory.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func remove(id: String, in directory: URL) {
        while let url = existing(id: id, in: directory) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                return
            }
        }
    }

    /// Формат по первым байтам: в списке FckCensor встречаются и m4a под видом mp3.
    private static func format(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 12 else { return nil }
        let bytes = [UInt8](head)
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return "flac" }
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 { return "m4a" }
        if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return "mp3" }
        if bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "aac" }
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return "mp3" }
        return nil
    }

    /// Держит кэш потока в пределах 400 МБ: старые файлы удаляются первыми.
    static func trimStreamCache(limit: Int64 = 400 << 20) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Storage.stream, includingPropertiesForKeys: keys)) ?? []
        var items = files.map { url -> (URL, Int64, Date) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.1 }
        items.sort { $0.2 < $1.2 }
        for item in items where total > limit {
            try? FileManager.default.removeItem(at: item.0)
            total -= item.1
        }
    }
}

/// Ход загрузки: у async-загрузки его видно только через Progress задачи.
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate {
    private let report: (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            report(progress.fractionCompleted)
        }
    }
}
