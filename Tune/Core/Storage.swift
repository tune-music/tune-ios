import CommonCrypto
import CryptoKit
import Foundation

/// Где лежат файлы. Скачанные треки и их обложки — в Application Support: эту папку iOS
/// сама не чистит. Кэш потока и картинок — в Caches: его система может удалить.
enum Storage {
    static let support: URL = make(.applicationSupportDirectory, keep: true)
    static let caches: URL = make(.cachesDirectory, keep: false)
    static let tracks: URL = sub(support, "Tracks")
    static let covers: URL = sub(support, "Covers")
    static let stream: URL = sub(caches, "Stream")
    static let images: URL = sub(caches, "Covers")
    /// Сохранённые списки треков и тексты песен: открываются без сети.
    static let lists: URL = sub(support, "Lists")
    static let lyrics: URL = sub(support, "Lyrics")

    private static func make(_ directory: FileManager.SearchPathDirectory, keep: Bool) -> URL {
        var url = FileManager.default.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent("Tune", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if keep {
            // Музыку незачем отправлять в резервную копию iCloud.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return url
    }

    private static func sub(_ base: URL, _ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: support.appendingPathComponent(name), options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: support.appendingPathComponent(name))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func size(of directory: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Тема: 0 — как в системе, 1 — тёмная, 2 — светлая.
    static var appearance: Int {
        get { defaults.object(forKey: "appearance") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "appearance") }
    }

    /// Версии треков без цензуры из открытого списка FckCensor.
    static var uncensor: Bool {
        get { defaults.object(forKey: "uncensor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "uncensor") }
    }

    /// Плавный переход между треками: −1 — «Авто» по точкам Яндекса, 0 — выключен,
    /// иначе ровный переход на столько секунд.
    static var crossfade: Int {
        get { defaults.object(forKey: "crossfade") as? Int ?? -1 }
        set { defaults.set(newValue, forKey: "crossfade") }
    }

    /// Синхронный текст из LRCLIB и NetEase, когда у Яндекса нет текста со временем строк.
    static var lyricsExternal: Bool {
        get { defaults.object(forKey: "lyricsExternal") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lyricsExternal") }
    }

    /// Искать в LRCLIB и NetEase и там, где у Яндекса есть свой текст.
    static var lyricsAlways: Bool {
        get { defaults.bool(forKey: "lyricsAlways") }
        set { defaults.set(newValue, forKey: "lyricsAlways") }
    }

    static var lyricsLRCLIB: Bool {
        get { defaults.object(forKey: "lyricsLRCLIB") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lyricsLRCLIB") }
    }

    static var lyricsNetEase: Bool {
        get { defaults.object(forKey: "lyricsNetEase") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lyricsNetEase") }
    }

    static var lyricsNetEaseFirst: Bool {
        get { defaults.bool(forKey: "lyricsNetEaseFirst") }
        set { defaults.set(newValue, forKey: "lyricsNetEaseFirst") }
    }

    /// Своё зеркало LRCLIB: адрес сервера с тем же API.
    static var lyricsMirror: String {
        get { defaults.string(forKey: "lyricsMirror") ?? "" }
        set { defaults.set(newValue, forKey: "lyricsMirror") }
    }

    /// Громкие записи приглушаются до общего уровня.
    static var normalize: Bool {
        get { defaults.bool(forKey: "normalize") }
        set { defaults.set(newValue, forKey: "normalize") }
    }

    /// lossless — лучшее, nq — обычное, lq — экономное.
    static var streamQuality: String {
        get { defaults.string(forKey: "streamQuality") ?? "lossless" }
        set { defaults.set(newValue, forKey: "streamQuality") }
    }

    static var downloadQuality: String {
        get { defaults.string(forKey: "downloadQuality") ?? "lossless" }
        set { defaults.set(newValue, forKey: "downloadQuality") }
    }

    /// Скачивать только по Wi-Fi: сотовая сеть и раздача с телефона не тратятся.
    static var wifiOnly: Bool {
        get { defaults.bool(forKey: "wifiOnly") }
        set { defaults.set(newValue, forKey: "wifiOnly") }
    }

    /// Офлайн-режим: в списках сразу показано только скачанное.
    static var offlineMode: Bool {
        get { defaults.bool(forKey: "offlineMode") }
        set { defaults.set(newValue, forKey: "offlineMode") }
    }

    /// Плейлисты, которые скачиваются сами: их номера.
    static var autoPlaylists: [String] {
        get { defaults.stringArray(forKey: "autoPlaylists") ?? [] }
        set { defaults.set(newValue, forKey: "autoPlaylists") }
    }

    /// Скачивать всё, что попало в «Мне нравится».
    static var autoLikes: Bool {
        get { defaults.bool(forKey: "autoLikes") }
        set { defaults.set(newValue, forKey: "autoLikes") }
    }
}

/// Аккаунт, в который входили на этом устройстве.
struct Account: Codable, Identifiable, Hashable {
    var uid: String
    var name: String
    var login: String
    var token: String

    var id: String { uid }
}

/// Список аккаунтов с их токенами: между ними можно переключаться без нового входа.
enum AccountStore {
    private static let file = Storage.support.appendingPathComponent("accounts")

    static func load() -> [Account] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    static func save(_ accounts: [Account]) {
        guard !accounts.isEmpty, let data = try? JSONEncoder().encode(accounts) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    }
}

/// Токен входа. Читается из любых потоков.
enum TokenStore {
    private static let lock = NSLock()
    private static let file = Storage.support.appendingPathComponent("token")
    private static var value: String? = {
        let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }()

    static var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    static func set(_ token: String?) {
        lock.lock()
        value = token
        lock.unlock()
        guard let token else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? token.write(to: file, atomically: true, encoding: .utf8)
        // Плеер читает токен и с заблокированным экраном.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    }
}

struct TuneError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Файл с transport=encraw зашифрован AES-CTR с нулевым счётчиком.
enum AESCTR {
    static func decrypt(file source: URL, to target: URL, keyHex: String) throws {
        let key = try bytes(hex: keyHex)
        guard key.count == 16 || key.count == 32 else { throw TuneError("Неверный ключ файла") }
        let iv = [UInt8](repeating: 0, count: 16)
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            iv, key, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        guard created == CCCryptorStatus(kCCSuccess), let cryptor else { throw TuneError("Не удалось расшифровать файл") }
        defer { CCCryptorRelease(cryptor) }

        FileManager.default.createFile(atPath: target.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: target)
        defer {
            try? input.close()
            try? output.close()
        }
        let capacity = 1 << 18
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            guard let chunk = try input.read(upToCount: capacity), !chunk.isEmpty else { break }
            var moved = 0
            let status = chunk.withUnsafeBytes { pointer in
                CCCryptorUpdate(cryptor, pointer.baseAddress, chunk.count, &buffer, capacity, &moved)
            }
            guard status == CCCryptorStatus(kCCSuccess) else { throw TuneError("Не удалось расшифровать файл") }
            try output.write(contentsOf: Data(buffer[0..<moved]))
        }
    }

    private static func bytes(hex: String) throws -> [UInt8] {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { throw TuneError("Неверный ключ файла") }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { throw TuneError("Неверный ключ файла") }
            out.append(byte)
            index += 2
        }
        return out
    }
}
