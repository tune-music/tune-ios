import Foundation

struct ReplacementTarget: Hashable {
    enum Kind: String, Hashable { case track, album, artist }
    let kind: Kind
    let id: String
    let title: String
    var key: String { "\(kind.rawValue):\(id)" }
}

struct MetadataOverride: Codable, Equatable {
    var title = ""
    var artists = ""
    var cover = ""
    var image: String?
    var audio: String?
    var tracks = ""
    var albums = ""
    var usePlugin = true

    var coverURI: String? { image.map { "tune-override:" + $0 } ?? (cover.isEmpty ? nil : cover) }

    static func ids(_ text: String, kind: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { token in
            let value = String(token)
            if value.utf8.allSatisfy({ (48...57).contains($0) }) { return value }
            guard let url = URL(string: value), let host = url.host, host == "music.yandex.ru" else { return nil }
            let components = url.pathComponents
            guard let index = components.lastIndex(of: kind), components.indices.contains(index + 1) else { return nil }
            let id = components[index + 1]
            return id.utf8.allSatisfy { (48...57).contains($0) } ? id : nil
        }
    }
}

final class MetadataOverrides {
    static let shared = MetadataOverrides()
    static let changed = Notification.Name("tune.metadataOverrideChanged")
    private let lock = NSLock()
    private let store = "metadata-overrides.json"
    private var values: [String: MetadataOverride] = Storage.load("metadata-overrides.json") ?? [:]

    private init() {}

    func value(_ kind: ReplacementTarget.Kind, _ id: String) -> MetadataOverride? {
        lock.lock()
        defer { lock.unlock() }
        return values["\(kind.rawValue):\(id)"]
    }

    func save(_ value: MetadataOverride?, target: ReplacementTarget) {
        lock.lock()
        let old = values[target.key]
        values[target.key] = value
        Storage.save(values, store)
        lock.unlock()
        for name in [old?.audio, old?.image].compactMap({ $0 }) where name != value?.audio && name != value?.image {
            if let url = Self.file(name) { try? FileManager.default.removeItem(at: url) }
        }
        NotificationCenter.default.post(name: Self.changed, object: target)
    }

    static func file(_ name: String) -> URL? {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, name != ".", name != ".." else { return nil }
        return Storage.support.appendingPathComponent("Overrides", isDirectory: true).appendingPathComponent(name)
    }

    static func importAudio(_ picked: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let access = picked.startAccessingSecurityScopedResource()
            defer { if access { picked.stopAccessingSecurityScopedResource() } }
            let valid = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "caf", "mp4"]
            let ext = picked.pathExtension.lowercased()
            guard valid.contains(ext) else { throw APIError.server("Выберите аудиофайл, который поддерживает iOS") }
            let name = UUID().uuidString + "." + ext
            guard let url = Self.file(name) else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: picked, to: url)
            return name
        }.value
    }

    static func importImage(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let data = ImageLoader.playlistCoverJPEG(data) else { throw APIError.server("Не удалось открыть изображение") }
            let name = UUID().uuidString + ".jpg"
            guard let url = Self.file(name) else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return name
        }.value
    }
}
