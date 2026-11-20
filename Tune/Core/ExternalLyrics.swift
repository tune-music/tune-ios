import Foundation

/// Синхронный текст песен не только от Яндекса, как в Tune Native: из LRCLIB (открытая база)
/// и NetEase Cloud Music (много синхронных текстов, в том числе русских).
///
/// Поиск отдаёт и чужие треки с похожим названием, поэтому берётся только совпадение по
/// названию, исполнителю и длительности. Синхронный текст лучше простого: простой берём, только
/// если синхронного не нашлось нигде.
enum ExternalLyrics {
    private static let agent = "Tune iOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")"
    private static let maxResponseBytes = 512 * 1024

    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d+):([0-5]?\d(?:[.,]\d+)?)\]"#)
    private static let offsetRegex = try! NSRegularExpression(pattern: #"(?im)^\[offset:([+-]?\d+)\]"#)

    private static let noRedirect = NoRedirectDelegate()
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: noRedirect, delegateQueue: nil)
    }()
    typealias Request = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let liveRequest: Request = { try await session.data(for: $0) }

    struct RequestFailure: LocalizedError {
        let host: String
        let path: String
        let details: String

        var errorDescription: String? { "\(host)\(path): \(details)" }
    }

    /// Настройки источников текста, которые можно передать явно (в том числе в тестах).
    struct Options: Equatable {
        var external: Bool
        var always: Bool
        var lrclib: Bool
        var netease: Bool
        var neteaseFirst: Bool
        var mirror: String

        static var current: Options {
            Options(
                external: Settings.lyricsExternal,
                always: Settings.lyricsAlways,
                lrclib: Settings.lyricsLRCLIB,
                netease: Settings.lyricsNetEase,
                neteaseFirst: Settings.lyricsNetEaseFirst,
                mirror: Settings.lyricsMirror
            )
        }
    }

    enum Source: Hashable {
        case yandex, lrclib, netease
    }

    /// Адреса NetEase: один и тот же API, но у разных адресов разные пути в сети —
    /// где-то один открывается без VPN, а другой только с ним.
    static let neteaseHosts = ["https://music.163.com", "https://interface.music.163.com", "https://interface3.music.163.com"]

    /// Адреса LRCLIB: своё зеркало из настроек (LRCLIB можно поднять у себя), затем основной.
    static var lrclibHosts: [String] {
        lrclibHosts(for: Settings.lyricsMirror)
    }

    static func lrclibHosts(for mirrorText: String) -> [String] {
        var hosts = ["https://lrclib.net"]
        if let mirror = mirror(mirrorText) { hosts.insert(mirror, at: 0) }
        return hosts
    }

    /// Адрес зеркала из настроек: только HTTPS, без учётных данных, query и fragment.
    static func mirror(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard !value.contains("?"), !value.contains("#"),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return nil
        }
        return components.string
    }

    private static func get(_ path: String, hosts: [String], netease: Bool = false, request: Request) async throws -> JSON {
        var failure: Error = URLError(.cannotConnectToHost)
        for host in hosts {
            try Task.checkCancellation()
            guard let url = URL(string: host + path), url.scheme == "https", let domain = url.host else { continue }
            var urlRequest = URLRequest(url: url, timeoutInterval: 6)
            urlRequest.httpShouldHandleCookies = false
            urlRequest.setValue(netease ? agent : "\(agent) (https://github.com/tune-music/tune-ios)", forHTTPHeaderField: "User-Agent")
            if netease { urlRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer") }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await request(urlRequest)
            } catch {
                try Task.checkCancellation()
                let code = error as NSError
                failure = RequestFailure(host: domain, path: url.path, details: "\(code.domain) (\(code.code))")
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 || status == 429 || status >= 500 || status == 0 {
                failure = RequestFailure(host: domain, path: url.path, details: "HTTP \(status)")
                continue
            }
            guard (200..<300).contains(status) else { return JSON(nil) }
            guard data.count <= maxResponseBytes else {
                failure = RequestFailure(host: domain, path: url.path, details: "Неверный ответ (\(data.count) байт)")
                continue
            }
            return JSON.parse(data)
        }
        throw failure
    }

    private static func enc(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.*")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
            .replacingOccurrences(of: "%20", with: "+")
    }

    /// Нормализует текст в слова через пробел: без регистра, с заменой «ё» на «е».
    static func cleanWords(_ text: String) -> String {
        var out = ""
        var needSpace = false
        for ch in text.lowercased().replacingOccurrences(of: "ё", with: "е") {
            if ch.isLetter || ch.isNumber {
                if needSpace, !out.isEmpty { out.append(" ") }
                out.append(ch)
                needSpace = false
            } else {
                needSpace = true
            }
        }
        return out
    }

    /// Убирает скобки с пометками `(feat. ...)`, `[Live]` и т.п.; если после этого ничего
    /// не осталось (например `(Nice Dream)`), возвращает очищенное исходное название.
    static func stripParens(_ text: String) -> String {
        var stripped = ""
        var depth = 0
        for ch in text {
            switch ch {
            case "(", "[", "（": depth += 1
            case ")", "]", "）": depth = max(depth - 1, 0)
            default:
                if depth == 0 { stripped.append(ch) }
            }
        }
        let cleaned = cleanWords(stripped)
        return cleaned.isEmpty ? cleanWords(text) : cleaned
    }

    /// Строки с авторами, что NetEase и LRCLIB ставят в начало текста: «作词 : …», «Lyrics by …».
    static func isCredit(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        let head = String(t.prefix { $0 != ":" && $0 != "：" })
        if head.count == t.count || head.count > 24 { return false }
        let h = head.trimmingCharacters(in: .whitespaces).lowercased()
        if h.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return true }
        let words = ["lyrics", "lyricist", "composer", "composed", "written", "producer", "produced", "arranger", "arranged", "mixing", "mixed",
                     "mastering", "текст", "слова", "музыка", "автор", "аранжировка", "сведение", "мастеринг"]
        return words.contains { h.hasPrefix($0) }
    }

    /// Разбор LRC и обычного текста: поддерживает несколько меток на одной строке, `[offset:...]`,
    /// запятые в долях секунды и сортировку по времени.
    static func parseLRC(_ text: String) -> [LyricLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let fullRange = NSRange(normalized.startIndex..., in: normalized)
        var offsetSeconds: Double = 0
        if let offsetMatch = offsetRegex.firstMatch(in: normalized, range: fullRange),
           let groupRange = Range(offsetMatch.range(at: 1), in: normalized),
           let ms = Double(normalized[groupRange]) {
            offsetSeconds = ms / 1000.0
        }

        var rawLines: [(time: Double?, text: String)] = []
        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let nsLine = line as NSString
            let matches = timestampRegex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            if !matches.isEmpty {
                let lastEnd = matches.last!.range.location + matches.last!.range.length
                let words = nsLine.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
                for match in matches {
                    let minText = nsLine.substring(with: match.range(at: 1))
                    let secText = nsLine.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: ".")
                    let minutes = Double(minText) ?? 0
                    guard let seconds = Double(secText) else { continue }
                    let time = max(0, minutes * 60 + seconds + offsetSeconds)
                    rawLines.append((time, words))
                }
            } else if line.hasPrefix("[") && line.hasSuffix("]") && line.contains(":") {
                // Служебная строка вроде [ar:…] или [ti:…] — не текст.
                continue
            } else {
                rawLines.append((nil, line))
            }
        }

        if rawLines.contains(where: { $0.time != nil }) {
            rawLines = rawLines.enumerated().sorted { lhs, rhs in
                let lt = lhs.element.time ?? .infinity
                let rt = rhs.element.time ?? .infinity
                return lt == rt ? lhs.offset < rhs.offset : lt < rt
            }.map(\.element)
        }
        return rawLines.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    /// Фильтрует заглушку Яндекса вида «текст доступен по подписке».
    static func filterYandex(_ lines: [LyricLine]) -> [LyricLine] {
        lines.filter { !$0.text.localizedCaseInsensitiveContains("текст доступен по подписке") }
    }

    /// Вместо текста пришла заглушка про подписку: пара строк со словом «подписка».
    static func isStub(_ lines: [LyricLine]) -> Bool {
        let words = lines.map(\.text).filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 4 else { return false }
        return words.joined(separator: " ").lowercased().contains("подписк")
    }

    /// Тот же ли это трек: название, хоть один исполнитель и длительность в пределах 8 секунд.
    private static func same(_ track: Track, title: String, artist: String, seconds: Int) -> Bool {
        let duration = track.durationMs > 0 ? Int((Double(track.durationMs) / 1000.0).rounded()) : 0
        guard duration == 0 || seconds == 0 || abs(seconds - duration) <= 8 else { return false }

        let candidateClean = cleanWords(title)
        guard !candidateClean.isEmpty else { return false }
        let candidateStripped = stripParens(title)
        let titles = [track.title, track.fullTitle]
        let titleOK = titles.contains { mine in
            let mineClean = cleanWords(mine)
            if !mineClean.isEmpty && mineClean == candidateClean { return true }
            let mineStripped = stripParens(mine)
            return !mineStripped.isEmpty && !candidateStripped.isEmpty && mineStripped == candidateStripped
        }
        guard titleOK else { return false }

        let theirs = cleanWords(artist)
        if theirs.isEmpty { return true }
        let theirsCompact = theirs.replacingOccurrences(of: " ", with: "")
        let mineList = track.artistList.map(\.name) + [track.artists]
        return mineList.contains { raw in
            let mine = cleanWords(raw)
            guard !mine.isEmpty else { return false }
            if (" " + theirs + " ").contains(" " + mine + " ") || (" " + mine + " ").contains(" " + theirs + " ") {
                return true
            }
            let mineCompact = mine.replacingOccurrences(of: " ", with: "")
            if theirsCompact == mineCompact { return true }
            return mineCompact.count >= 3 && theirsCompact.count >= 3 &&
                (theirsCompact.contains(mineCompact) || mineCompact.contains(theirsCompact))
        }
    }

    private static func firstArtist(_ track: Track) -> String {
        track.artistList.first?.name ?? track.artists
    }

    /// Текст из чужой базы: без строк с авторами.
    private static func external(_ text: String, _ source: String) -> LyricsText {
        external(parseLRC(text), source)
    }

    private static func external(_ raw: [LyricLine], _ source: String) -> LyricsText {
        let lines = filterYandex(raw)
            .filter { !isCredit($0.text) }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
        return LyricsText(lines: lines, authors: nil, source: source)
    }

    static func synced(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.time != nil }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Текст из LRCLIB: точное совпадение, а нет его — поиск.
    static func fetchLRCLIB(_ track: Track, mirrorText: String = Settings.lyricsMirror, request: Request = liveRequest) async throws -> LyricsText? {
        let artist = firstArtist(track)
        let base = "track_name=\(enc(track.title))&artist_name=\(enc(artist))"
        var query = base
        if track.durationMs >= 1000 { query += "&duration=\(track.durationMs / 1000)" }
        if !track.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query += "&album_name=\(enc(track.albumTitle))"
        }
        let hosts = lrclibHosts(for: mirrorText)
        let exact: JSON
        var exactFailure: Error?
        do {
            exact = try await get("/api/get?\(query)", hosts: hosts, request: request)
        } catch {
            try Task.checkCancellation()
            exact = JSON(nil)
            exactFailure = error
        }
        if let text = string(exact["syncedLyrics"].string) { return external(text, "LRCLIB") }
        let candidates: [JSON]
        do {
            let payload = try await get("/api/search?\(base)", hosts: hosts, request: request)
            candidates = payload.array.filter {
                matches(track, lyricHit: ($0["trackName"].string ?? "", $0["artistName"].string ?? "", $0["duration"].int ?? 0))
            }
        } catch {
            try Task.checkCancellation()
            if let text = string(exact["plainLyrics"].string) { return external(text, "LRCLIB") }
            throw error
        }
        let result = candidates.first { string($0["syncedLyrics"].string) != nil }
            ?? (exact.isObject ? exact : candidates.first)
        if let result, let text = string(result["syncedLyrics"].string) ?? string(result["plainLyrics"].string) {
            return external(text, "LRCLIB")
        }
        if let exactFailure { throw exactFailure }
        return nil
    }

    static func fetchNetEase(_ track: Track, request: Request = liveRequest) async throws -> LyricsText? {
        let query = "\(firstArtist(track)) \(track.title)".trimmingCharacters(in: .whitespaces)
        let hits = try await neteaseHits(query, type: 1, request: request)
        var failure: Error?
        for hit in hits.filter({ matches(track, lyricHit: $0.track) }).prefix(3) {
            guard let id = hit.id, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            do {
                let lyric = try await get("/api/song/lyric?id=\(id)&lv=1", hosts: neteaseHosts, netease: true, request: request)
                let raw = parseLRC(lyric["lrc"]["lyric"].string ?? "")
                if raw.filter({ $0.time != nil && !$0.text.isEmpty }).count >= 4 {
                    return external(raw, "NetEase")
                }
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        if let failure { throw failure }
        return nil
    }

    static func searchByLine(_ line: String) async throws -> [(title: String, artist: String, seconds: Int)] {
        guard Settings.lyricsExternal, Settings.lyricsNetEase, line.split(whereSeparator: \.isWhitespace).count >= 2 else { return [] }
        return try await neteaseHits(line, type: 1006, request: liveRequest).map(\.track)
    }

    private typealias Hit = (title: String, artist: String, seconds: Int)

    private static func neteaseHits(_ query: String, type: Int, request: Request) async throws -> [(id: String?, track: Hit)] {
        let payload = try await get("/api/search/get?s=\(enc(query))&type=\(type)&limit=8", hosts: neteaseHosts, netease: true, request: request)
        return payload["result"]["songs"].array.compactMap { song in
            guard let title = song["name"].string else { return nil }
            let artist = song["artists"].array.compactMap { $0["name"].string }.joined(separator: " ")
            guard !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (song["id"].idText, (title, artist, (song["duration"].int ?? 0) / 1000))
        }
    }

    static func matches(_ track: Track, lyricHit: (title: String, artist: String, seconds: Int)) -> Bool {
        same(track, title: lyricHit.title, artist: lyricHit.artist, seconds: lyricHit.seconds)
    }

    /// Кнопка текста доступна всегда — как в Android-версии: если текста нет у Яндекса,
    /// его можно поискать в базах или прочитать из встроенных метаданных файла.
    static func available(_ track: Track) -> Bool {
        true
    }

    /// Настройки, с которыми искали текст: поменялись — сохранённый текст ищется заново.
    static func settingsKey(for options: Options) -> String {
        guard options.external else { return "v5:yandex" }
        return "v5:" + [options.always, options.lrclib, options.netease, options.neteaseFirst]
            .map { $0 ? "1" : "0" }.joined() + (mirror(options.mirror) ?? "")
    }

    static var settingsKey: String { settingsKey(for: .current) }

    /// Принимает сохранённый текст из кэша, учитывая режим без сети и текущие настройки.
    static func acceptCached(_ saved: LyricsText, options: Options = .current, anySource: Bool) -> LyricsText? {
        guard !saved.lines.isEmpty, !isStub(saved.lines) else { return nil }
        if anySource { return saved }
        if saved.searched == settingsKey(for: options) { return saved }
        guard saved.searched == nil else { return nil }
        return enabledFallback(saved, options: options)
    }

    static func enabledFallback(_ saved: LyricsText, options: Options) -> LyricsText? {
        switch saved.source {
        case "LRCLIB" where !options.external || !options.lrclib: return nil
        case "NetEase" where !options.external || !options.netease: return nil
        default: return saved
        }
    }

    static func find(
        _ track: Track,
        options: Options = .current,
        yandex: (String) async throws -> LyricsText,
        lrclib: ((Track) async throws -> LyricsText?)? = nil,
        netease: ((Track) async throws -> LyricsText?)? = nil,
        onFailure: ((Source, Error) -> Void)? = nil
    ) async -> (LyricsText, complete: Bool) {
        var sources: [Source] = track.isPrivate ? [] : [.yandex]
        if options.external {
            if options.neteaseFirst && options.netease { sources.append(.netease) }
            if options.lrclib { sources.append(.lrclib) }
            if !options.neteaseFirst && options.netease { sources.append(.netease) }
        }

        let empty = LyricsText(lines: [], authors: nil, source: nil)
        var fallback: LyricsText?
        var complete = true
        for source in sources {
            if Task.isCancelled { return (empty, false) }
            let result: LyricsText?
            do {
                switch source {
                case .yandex:
                    var own = try await yandex(track.id)
                    own.lines = filterYandex(own.lines)
                    own.source = own.source ?? LyricsText.yandex
                    result = own
                case .lrclib:
                    if let lrclib { result = try await lrclib(track) }
                    else { result = try await fetchLRCLIB(track, mirrorText: options.mirror) }
                case .netease:
                    if let netease { result = try await netease(track) }
                    else { result = try await fetchNetEase(track) }
                }
            } catch {
                if Task.isCancelled { return (empty, false) }
                onFailure?(source, error)
                complete = false
                continue
            }

            guard let result, !isStub(result.lines), result.lines.contains(where: { !$0.text.isEmpty }) else { continue }
            if result.synced && (source != .yandex || !options.external || !options.always) {
                return (result, true)
            }
            if fallback == nil { fallback = result }
        }
        if let fallback { return (fallback, true) }
        return (empty, complete)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
