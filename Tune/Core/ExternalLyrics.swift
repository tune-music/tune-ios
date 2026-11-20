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
    private static let preferenceGrace: UInt64 = 250_000_000

    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d+):([0-5]?\d(?:[.,]\d+)?)\]"#)
    private static let offsetRegex = try! NSRegularExpression(pattern: #"(?im)^\[offset:([+-]?\d+)\]"#)

    private static let noRedirect = NoRedirectDelegate()
    private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config, delegate: noRedirect, delegateQueue: nil)
    }
    private static let session = makeSession(resourceTimeout: 12)
    private static let lrclibSession = makeSession(resourceTimeout: 20)
    typealias Request = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let liveRequest: Request = { try await session.data(for: $0) }
    static let liveLRCLIBRequest: Request = { try await lrclibSession.data(for: $0) }

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

    private static func get(_ path: String, host: String, headers: [String: String], timeout: TimeInterval, request: Request) async throws -> JSON {
        try Task.checkCancellation()
        guard let url = URL(string: host + path) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue(agent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await request(urlRequest)
        } catch {
            try Task.checkCancellation()
            let code = error as NSError
            throw RequestFailure(host: url.host ?? host, path: url.path, details: "\(code.domain) (\(code.code))")
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return JSON(nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw RequestFailure(host: url.host ?? host, path: url.path, details: "HTTP \(http.statusCode)")
        }
        guard data.count <= maxResponseBytes,
              let payload = try? JSONSerialization.jsonObject(with: data) else {
            throw RequestFailure(host: url.host ?? host, path: url.path, details: "Неверный ответ (\(data.count) байт)")
        }
        return JSON(payload)
    }

    private static func get(_ path: String, hosts: [String], headers: [String: String], request: Request) async throws -> JSON {
        var failure: Error = URLError(.cannotConnectToHost)
        var reached = false
        for host in hosts {
            do {
                let payload = try await get(path, host: host, headers: headers, timeout: 15, request: request)
                if payload.exists { return payload }
                reached = true
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        if reached { return JSON(nil) }
        throw failure
    }

    private static func enc(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
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
        let lines = parseLRC(text)
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
    static func fetchLRCLIB(_ track: Track, mirrorText: String = Settings.lyricsMirror, request: Request = liveLRCLIBRequest) async throws -> LyricsText? {
        let headers = ["User-Agent": "\(agent) (https://github.com/tune-music/tune-ios)"]
        let artist = firstArtist(track)
        var query = "track_name=\(enc(track.title))&artist_name=\(enc(artist))"
        if !track.albumTitle.isEmpty { query += "&album_name=\(enc(track.albumTitle))" }
        if track.duration > 0 { query += "&duration=\(Int(track.duration))" }
        let hosts = lrclibHosts(for: mirrorText)
        let exact: [String: Any]?
        var exactFailure: Error?
        do {
            exact = try await get("/api/get?\(query)", hosts: hosts, headers: headers, request: request).dict
        } catch {
            try Task.checkCancellation()
            exact = nil
            exactFailure = error
        }
        func pick(_ value: [String: Any]) -> LyricsText? {
            guard let text = string(value["syncedLyrics"]) ?? string(value["plainLyrics"]) else { return nil }
            let result = external(text, "LRCLIB")
            return result.lines.contains(where: { !$0.text.isEmpty }) ? result : nil
        }
        if let exact, string(exact["syncedLyrics"]) != nil, let found = pick(exact) { return found }
        let foldedTitle = track.title.replacingOccurrences(of: "ё", with: "е", options: .caseInsensitive)
        let foldedArtist = artist.replacingOccurrences(of: "ё", with: "е", options: .caseInsensitive)
        let original = "/api/search?track_name=\(enc(track.title))&artist_name=\(enc(artist))"
        let folded = "/api/search?track_name=\(enc(foldedTitle))&artist_name=\(enc(foldedArtist))"
        var plain = exact.flatMap(pick)
        for path in original == folded ? [original] : [original, folded] {
            do {
                let payload = try await get(path, hosts: hosts, headers: headers, request: request)
                for candidate in payload.array {
                    guard let value = candidate.dict,
                          same(track, title: candidate["trackName"].string ?? "", artist: candidate["artistName"].string ?? "",
                               seconds: candidate["duration"].int ?? 0),
                          let found = pick(value) else { continue }
                    if found.synced { return found }
                    if plain == nil { plain = found }
                }
            } catch {
                try Task.checkCancellation()
                if let plain { return plain }
                throw error
            }
        }
        if plain == nil, let exactFailure { throw exactFailure }
        return plain
    }

    static func fetchNetEase(_ track: Track, request: @escaping Request = liveRequest) async throws -> LyricsText? {
        let query = "\(firstArtist(track)) \(track.title)".trimmingCharacters(in: .whitespaces)
        return try await firstNetEaseResult { host in
            let hits = try await neteaseHits(query, type: 1, host: host, request: request)
            var failure: Error?
            for hit in hits.filter({ matches(track, lyricHit: $0.track) }).prefix(3) {
                guard let id = hit.id, !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
                do {
                    let lyric = try await netease("/api/song/lyric?id=\(id)&lv=1", host: host, request: request)
                    let parsed = external(lyric["lrc"]["lyric"].string ?? "", "NetEase")
                    if parsed.lines.filter({ $0.time != nil && !$0.text.isEmpty }).count >= 4 {
                        return parsed
                    }
                } catch {
                    try Task.checkCancellation()
                    failure = error
                }
            }
            if let failure { throw failure }
            return nil
        }
    }

    static func searchByLine(_ line: String) async throws -> [(title: String, artist: String, seconds: Int)] {
        guard Settings.lyricsExternal, Settings.lyricsNetEase, line.split(whereSeparator: \.isWhitespace).count >= 2 else { return [] }
        let result = try await firstNetEaseResult { host in
            let hits = try await neteaseHits(line, type: 1006, host: host, request: liveRequest)
            return hits.isEmpty ? nil : hits.map(\.track)
        }
        return result ?? []
    }

    private typealias Hit = (title: String, artist: String, seconds: Int)

    private static func neteaseHits(_ query: String, type: Int, host: String, request: Request) async throws -> [(id: String?, track: Hit)] {
        let payload = try await netease("/api/search/get?s=\(enc(query))&type=\(type)&limit=8", host: host, request: request)
        return payload["result"]["songs"].array.compactMap { song in
            guard let title = song["name"].string else { return nil }
            let artist = song["artists"].array.compactMap { $0["name"].string }.joined(separator: " ")
            guard !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (song["id"].idText, (title, artist, (song["duration"].int ?? 0) / 1000))
        }
    }

    private static func netease(_ path: String, host: String, request: Request) async throws -> JSON {
        let payload = try await get(path, host: host, headers: ["Referer": "https://music.163.com/"], timeout: 6, request: request)
        if payload.exists, (payload["code"].int ?? 200) != 200 { throw URLError(.badServerResponse) }
        return payload
    }

    private static func firstNetEaseResult<Value: Sendable>(_ lookup: @escaping @Sendable (String) async throws -> Value?) async throws -> Value? {
        try await withThrowingTaskGroup(of: Result<Value?, Error>.self) { group in
            for host in neteaseHosts {
                group.addTask {
                    do { return .success(try await lookup(host)) }
                    catch { return .failure(error) }
                }
            }
            var failure: Error?
            for try await result in group {
                try Task.checkCancellation()
                switch result {
                case .success(let value?):
                    group.cancelAll()
                    return value
                case .success(nil): break
                case .failure(let error): failure = error
                }
            }
            if let failure { throw failure }
            return nil
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
        guard options.external else { return "v4:yandex" }
        return "v4:" + [options.always, options.lrclib, options.netease, options.neteaseFirst]
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

    /// Текст трека и все ли источники ответили. Не ответил какой-то — найденное не
    /// окончательно, в следующий раз спросим снова.
    ///
    /// Источники опрашиваются одновременно. Приоритетный текст выигрывает, если успевает за короткую паузу.
    static func find(
        _ track: Track,
        options: Options = .current,
        yandex: @escaping @Sendable (String) async throws -> LyricsText,
        lrclib: (@Sendable (Track) async throws -> LyricsText?)? = nil,
        netease: (@Sendable (Track) async throws -> LyricsText?)? = nil,
        onFailure: (@Sendable (Source, Error) -> Void)? = nil
    ) async -> (LyricsText, complete: Bool) {
        let empty = LyricsText(lines: [], authors: nil, source: nil)
        let externalOrder: [Source] = {
            guard options.external else { return [] }
            let raw: [Source] = options.neteaseFirst ? [.netease, .lrclib] : [.lrclib, .netease]
            return raw.filter { source in
                switch source {
                case .lrclib: return options.lrclib
                case .netease: return options.netease
                case .yandex: return false
                }
            }
        }()
        let askYandex = !track.isPrivate
        let resolveLRCLIB: @Sendable (Track) async throws -> LyricsText? = lrclib ?? { t in
            try await fetchLRCLIB(t, mirrorText: options.mirror)
        }
        let resolveNetEase: @Sendable (Track) async throws -> LyricsText? = netease ?? { t in
            try await fetchNetEase(t)
        }

        let fetchSource: @Sendable (Source) async throws -> LyricsText? = { source in
            switch source {
            case .yandex:
                let raw = try await yandex(track.id)
                let clean = filterYandex(raw.lines)
                guard !clean.isEmpty, !isStub(clean), clean.contains(where: { !$0.text.isEmpty }) else {
                    return nil
                }
                return LyricsText(lines: clean, authors: raw.authors, source: raw.source ?? LyricsText.yandex)
            case .lrclib:
                let found = try await resolveLRCLIB(track)
                return (found?.lines.isEmpty ?? true) ? nil : found
            case .netease:
                let found = try await resolveNetEase(track)
                return (found?.lines.isEmpty ?? true) ? nil : found
            }
        }

        let priority: [Source] = if options.always && !externalOrder.isEmpty {
            externalOrder + (askYandex ? [.yandex] : [])
        } else {
            (askYandex ? [.yandex] : []) + externalOrder
        }
        guard !priority.isEmpty else { return (empty, true) }

        let result = await resolvePriority(priority, waitForExternal: options.always, fetch: fetchSource, onFailure: onFailure)
        if let winner = result.syncedWinner {
            return (winner, result.complete)
        }
        let plain = result.found[.yandex] ?? externalOrder.compactMap { result.found[$0] }.first ?? empty
        return (plain, result.complete)
    }

    private static func resolvePriority(
        _ order: [Source],
        waitForExternal: Bool,
        fetch: @escaping @Sendable (Source) async throws -> LyricsText?,
        onFailure: (@Sendable (Source, Error) -> Void)?
    ) async -> (found: [Source: LyricsText], syncedWinner: LyricsText?, complete: Bool) {
        await withTaskGroup(of: (Source?, LyricsText?, Bool).self) { group in
            defer { group.cancelAll() }
            for source in order {
                group.addTask {
                    do {
                        let found = try await fetch(source)
                        return (source, found, true)
                    } catch {
                        if !Task.isCancelled { onFailure?(source, error) }
                        return (source, nil, false)
                    }
                }
            }
            var found: [Source: LyricsText] = [:]
            var finished: Set<Source> = []
            var reachedSources: Set<Source> = []
            var waitingForPreference = false
            for await (source, text, reached) in group {
                guard let source else {
                    let winner = order.compactMap { found[$0] }.first(where: \.synced)
                    return (found, winner, false)
                }
                finished.insert(source)
                if reached { reachedSources.insert(source) }
                if let text, !text.lines.isEmpty { found[source] = text }
                for candidateSource in order {
                    if let candidate = found[candidateSource], candidate.synced {
                        let definitive = order.prefix(while: { $0 != candidateSource }).allSatisfy { reachedSources.contains($0) }
                        return (found, candidate, definitive)
                    }
                    if !finished.contains(candidateSource) {
                        break
                    }
                }
                if finished.count == order.count { break }
                if !waitingForPreference, text?.synced == true, !(waitForExternal && source == .yandex) {
                    waitingForPreference = true
                    group.addTask {
                        try? await Task.sleep(nanoseconds: preferenceGrace)
                        return (nil, nil, false)
                    }
                }
            }
            return (found, nil, reachedSources.count == order.count)
        }
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
