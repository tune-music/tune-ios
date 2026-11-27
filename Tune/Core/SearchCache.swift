import Foundation

actor SearchCache {
    static let shared = SearchCache()

    struct Key: Codable, Equatable {
        let account: String
        let query: String
        let tab: String
        let uncensor: Bool
        let catalog: Bool
    }

    private struct Entry: Codable {
        let key: Key
        let result: SearchResult
    }

    private let file = Storage.caches.appendingPathComponent("search-results.json")
    private let limit = 24
    private lazy var entries: [Entry] = {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(saved.prefix(limit))
    }()

    func result(for key: Key) -> SearchResult? {
        entries.first { $0.key == key }?.result
    }

    func save(_ result: SearchResult, for key: Key) {
        entries.removeAll { $0.key == key }
        if !result.isEmpty { entries.insert(Entry(key: key, result: result), at: 0) }
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    func clear(account: String) {
        entries.removeAll { $0.key.account == account }
        persist()
    }

    func clearAll() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
