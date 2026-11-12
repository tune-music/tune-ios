import Foundation

/// Загрузка файлов через фоновую сессию: система продолжает её, когда приложение свёрнуто
/// или выгружено из памяти, и будит приложение, когда файл готов.
final class BackgroundFetcher: NSObject, URLSessionDownloadDelegate {
    static let shared = BackgroundFetcher()

    private struct Waiting {
        let done: CheckedContinuation<(URL, URLResponse), Error>
        let progress: (Double) -> Void
        var file: URL?
    }

    private let lock = NSLock()
    private var waiting: [Int: Waiting] = [:]
    /// Система ждёт этот вызов, когда разбудила приложение ради готовых загрузок.
    private var wake: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "dev.tune.music.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Подключается к сессии после запуска. Загрузки, оставшиеся от прошлого запуска, никто
    /// уже не ждёт: они отменяются, а очередь скачивания начинает их заново.
    func start() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.lock.lock()
            let known = Set(self.waiting.keys)
            self.lock.unlock()
            for task in tasks where !known.contains(task.taskIdentifier) { task.cancel() }
        }
    }

    func setWake(_ handler: @escaping () -> Void) {
        lock.lock()
        wake = handler
        lock.unlock()
    }

    func download(_ request: URLRequest, progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<(URL, URLResponse), Error>) in
                lock.lock()
                waiting[task.taskIdentifier] = Waiting(done: done, progress: progress, file: nil)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Временный файл система удалит сразу после этого вызова: забираем его себе.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        lock.lock()
        if moved { waiting[downloadTask.taskIdentifier]?.file = kept }
        let known = waiting[downloadTask.taskIdentifier] != nil
        lock.unlock()
        if moved, !known { try? FileManager.default.removeItem(at: kept) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let report = waiting[downloadTask.taskIdentifier]?.progress
        lock.unlock()
        report?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = waiting.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else { return }
        if let error {
            if let file = entry.file { try? FileManager.default.removeItem(at: file) }
            entry.done.resume(throwing: error)
        } else if let file = entry.file, let response = task.response {
            entry.done.resume(returning: (file, response))
        } else {
            entry.done.resume(throwing: TuneError("Файл трека не скачался"))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = wake
        wake = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}
