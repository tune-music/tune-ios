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

    /// Отдельная сессия без cookies, кэша и авто-редиректов: долгоживущая cookie `NMTID` от NetEase
    /// переводит поиск в режим подмены выдачи на случайные китайские треки.
    private static let noRedirect = NoRedirectDelegate()
    private static let session: URLSession = {
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies where cookie.domain.contains("163.com") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config, delegate: noRedirect, delegateQueue: nil)
    }()

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

    /// Память о рабочих и отказавших зеркалах, чтобы не ждать недоступный адрес.
    private static let memory = HostMemory()

    /// Запрос к базе: по очереди к каждому адресу, пока какой-то не ответит.
    /// Ответ «не нашлось» — тоже ответ: дальше по адресам не идём.
    private static func get(_ path: String, hosts: [String], headers: [String: String], netease: Bool = false) async throws -> Any? {
        var failure: Error = URLError(.cannotConnectToHost)
        for host in await memory.order(hosts) {
            guard let url = URL(string: host + path) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await memory.failed(host, among: hosts)
                    continue
                }
                // Редирект, заглушка провайдера, антибот или слишком большой ответ — пробуем другой адрес.
                if (300..<400).contains(http.statusCode) || http.statusCode == 403 || http.statusCode == 429 ||
                    http.statusCode >= 500 || data.count > maxResponseBytes {
                    await memory.failed(host, among: hosts)
                    failure = URLError(.badServerResponse)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    await memory.worked(host, among: hosts)
                    return nil
                }
                let json = try? JSONSerialization.jsonObject(with: data)
                if netease, let dict = json as? [String: Any],
                   let code = (dict["code"] as? NSNumber)?.intValue, code != 200 {
                    await memory.failed(host, among: hosts)
                    failure = URLError(.badServerResponse)
                    continue
                }
                await memory.worked(host, among: hosts)
                return json
            } catch {
                if Task.isCancelled { throw error }
                await memory.failed(host, among: hosts)
                failure = error
            }
        }
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
    static func fetchLRCLIB(_ track: Track, mirrorText: String = Settings.lyricsMirror) async throws -> LyricsText? {
        let headers = ["Lrclib-Client": "Tune iOS"]
        let artist = firstArtist(track)
        var query = "track_name=\(enc(track.title))&artist_name=\(enc(artist))"
        if !track.albumTitle.isEmpty { query += "&album_name=\(enc(track.albumTitle))" }
        if track.duration > 0 { query += "&duration=\(Int(track.duration))" }
        let hosts = lrclibHosts(for: mirrorText)
        let exact = try await get("/api/get?\(query)", hosts: hosts, headers: headers) as? [String: Any]
        func pick(_ value: [String: Any]) -> LyricsText? {
            guard let text = string(value["syncedLyrics"]) ?? string(value["plainLyrics"]) else { return nil }
            let result = external(text, "LRCLIB")
            return result.lines.contains(where: { !$0.text.isEmpty }) ? result : nil
        }
        if let exact, string(exact["syncedLyrics"]) != nil, let found = pick(exact) { return found }
        let list = try await get("/api/search?track_name=\(enc(track.title))&artist_name=\(enc(artist))", hosts: hosts, headers: headers) as? [[String: Any]] ?? []
        let matching = list.filter {
            same(track, title: $0["trackName"] as? String ?? "", artist: $0["artistName"] as? String ?? "", seconds: Int(((($0["duration"] as? NSNumber)?.doubleValue) ?? 0).rounded()))
        }
        let chosen = matching.first { string($0["syncedLyrics"]) != nil } ?? exact ?? matching.first
        return chosen.flatMap(pick)
    }

    /// Синхронный текст из NetEase, если там именно этот трек.
    static func fetchNetEase(_ track: Track) async throws -> LyricsText? {
        let headers = ["Referer": "https://music.163.com/"]
        let query = "\(firstArtist(track)) \(track.title)".trimmingCharacters(in: .whitespaces)
        guard let found = try await get("/api/search/get?s=\(enc(query))&type=1&limit=8", hosts: neteaseHosts, headers: headers, netease: true) as? [String: Any] else { return nil }
        let songs = ((found["result"] as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        let matching = songs.filter { song in
            let artist = ((song["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: " ")
            // «Miyagi & Andy Panda» у NetEase — один исполнитель, у Яндекса — два.
            return !artist.isEmpty && same(track, title: song["name"] as? String ?? "", artist: artist, seconds: ((song["duration"] as? NSNumber)?.intValue ?? 0) / 1000)
        }
        for song in matching.prefix(3) {
            guard let id = (song["id"] as? NSNumber)?.int64Value else { continue }
            guard let lyric = try await get("/api/song/lyric?id=\(id)&lv=1", hosts: neteaseHosts, headers: headers, netease: true) as? [String: Any] else { continue }
            let lrc = ((lyric["lrc"] as? [String: Any])?["lyric"] as? String) ?? ""
            let parsed = external(lrc, "NetEase")
            // Хотя бы несколько строк со временем и текстом — иначе это пустышка или «纯音乐».
            if parsed.lines.filter({ $0.time != nil && !$0.text.isEmpty }).count >= 4 {
                return parsed
            }
        }
        return nil
    }

    static func searchByLine(_ line: String) async throws -> [(title: String, artist: String, seconds: Int)] {
        guard Settings.lyricsExternal, Settings.lyricsNetEase, line.split(whereSeparator: \.isWhitespace).count >= 2 else { return [] }
        let headers = ["Referer": "https://music.163.com/"]
        let payload = try await get(
            "/api/search/get?s=\(enc(line))&type=1006&limit=8", hosts: neteaseHosts, headers: headers, netease: true
        )
        let found = JSON(payload)
        guard found["code"].int == 200 else { throw URLError(.badServerResponse) }
        return found["result"]["songs"].array.compactMap { song in
            guard let title = song["name"].string else { return nil }
            let artist = song["artists"].array.compactMap { $0["name"].string }.joined(separator: " ")
            guard !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (title, artist, (song["duration"].int ?? 0) / 1000)
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
        guard options.external else { return "yandex" }
        return [options.always, options.lrclib, options.netease, options.neteaseFirst]
            .map { $0 ? "1" : "0" }.joined() + (mirror(options.mirror) ?? "")
    }

    static var settingsKey: String { settingsKey(for: .current) }

    /// Принимает сохранённый текст из кэша, учитывая режим без сети и текущие настройки.
    static func acceptCached(_ saved: LyricsText, options: Options = .current, anySource: Bool) -> LyricsText? {
        guard !saved.lines.isEmpty, !isStub(saved.lines) else { return nil }
        if anySource { return saved }
        if saved.searched == settingsKey(for: options) { return saved }
        // Старый кэш мог остаться без ключа.
        guard saved.searched == nil else { return nil }
        switch saved.source {
        case "LRCLIB" where !options.external || !options.lrclib: return nil
        case "NetEase" where !options.external || !options.netease: return nil
        default: return saved
        }
    }

    /// Текст трека и все ли источники ответили. Не ответил какой-то — найденное не
    /// окончательно, в следующий раз спросим снова.
    ///
    /// Когда у трека уже ожидается текст Яндекса и «Искать и там, где у Яндекса есть свой текст»
    /// выключено, сначала спрашиваем только Яндекс; если там синхронного нет, параллельно
    /// опрашиваем внешние базы в порядке приоритета. В остальных случаях все источники идут
    /// одновременно, но более приоритетный синхронный текст не уступает быстрому низкоприоритетному.
    static func find(
        _ track: Track,
        options: Options = .current,
        yandex: @escaping @Sendable (String) async throws -> LyricsText,
        lrclib: (@Sendable (Track) async throws -> LyricsText?)? = nil,
        netease: (@Sendable (Track) async throws -> LyricsText?)? = nil
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

        // Быстрый путь: у Яндекса помечен свой текст и внешние базы не приоритетнее.
        if askYandex && track.hasLyrics && (!options.always || externalOrder.isEmpty) {
            var yandexPlain: LyricsText?
            var yandexReached = true
            do {
                if let own = try await fetchSource(.yandex) {
                    if own.synced { return (own, true) }
                    yandexPlain = own
                }
            } catch {
                if Task.isCancelled { return (empty, false) }
                yandexReached = false
            }
            if externalOrder.isEmpty {
                return (yandexPlain ?? empty, yandexReached)
            }
            let result = await resolvePriority(externalOrder, fetch: fetchSource)
            if let winner = result.syncedWinner {
                return (winner, true)
            }
            let plain = yandexPlain ?? externalOrder.compactMap { result.found[$0] }.first ?? empty
            return (plain, yandexReached && result.complete)
        }

        // Параллельный путь с уважением приоритета: Яндекс всегда проверяется у публичных треков,
        // даже если флаг `hasLyrics` в API оказался false.
        let priority: [Source] = if options.always && !externalOrder.isEmpty {
            externalOrder + (askYandex ? [.yandex] : [])
        } else {
            (askYandex ? [.yandex] : []) + externalOrder
        }
        guard !priority.isEmpty else { return (empty, true) }

        let result = await resolvePriority(priority, fetch: fetchSource)
        if let winner = result.syncedWinner {
            return (winner, true)
        }
        let plain = result.found[.yandex] ?? externalOrder.compactMap { result.found[$0] }.first ?? empty
        return (plain, result.complete)
    }

    private static func resolvePriority(
        _ order: [Source],
        fetch: @escaping @Sendable (Source) async throws -> LyricsText?
    ) async -> (found: [Source: LyricsText], syncedWinner: LyricsText?, complete: Bool) {
        await withTaskGroup(of: (Source, LyricsText?, Bool).self) { group in
            for source in order {
                group.addTask {
                    do {
                        let found = try await fetch(source)
                        return (source, found, true)
                    } catch {
                        return (source, nil, false)
                    }
                }
            }
            var found: [Source: LyricsText] = [:]
            var finished: Set<Source> = []
            var complete = true
            for await (source, text, reached) in group {
                finished.insert(source)
                if !reached { complete = false }
                if let text, !text.lines.isEmpty { found[source] = text }
                for candidateSource in order {
                    if let candidate = found[candidateSource], candidate.synced {
                        group.cancelAll()
                        return (found, candidate, true)
                    }
                    if !finished.contains(candidateSource) {
                        break
                    }
                }
            }
            return (found, nil, complete)
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

/// Какой адрес базы ответил последним и какие недавно отказали.
private actor HostMemory {
    private var lastGood: [String: String] = [:]
    private var recentFailed: [String: Set<String>] = [:]

    private func cacheKey(for hosts: [String]) -> String {
        hosts.sorted().joined(separator: "\n")
    }

    func order(_ hosts: [String]) -> [String] {
        let key = cacheKey(for: hosts)
        let good = lastGood[key]
        let bad = recentFailed[key] ?? []
        var preferred: [String] = []
        if let good, hosts.contains(good), !bad.contains(good) {
            preferred.append(good)
        }
        let neutral = hosts.filter { $0 != good && !bad.contains($0) }
        let degraded = hosts.filter { $0 != good && bad.contains($0) }
        return preferred + neutral + degraded
    }

    func worked(_ host: String, among hosts: [String]) {
        let key = cacheKey(for: hosts)
        lastGood[key] = host
        recentFailed[key]?.remove(host)
    }

    func failed(_ host: String, among hosts: [String]) {
        let key = cacheKey(for: hosts)
        recentFailed[key, default: []].insert(host)
        if lastGood[key] == host {
            lastGood[key] = nil
        }
    }
}
