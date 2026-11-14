import Foundation

/// Синхронный текст песен не только от Яндекса, как в Tune Native: из LRCLIB (открытая база)
/// и NetEase Cloud Music (много синхронных текстов, в том числе русских).
///
/// Поиск отдаёт и чужие треки с похожим названием, поэтому берётся только совпадение по
/// названию, исполнителю и длительности. Синхронный текст лучше простого: простой берём, только
/// если синхронного не нашлось нигде.
enum ExternalLyrics {
    private static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"

    private static func get(_ address: String, headers: [String: String]) async throws -> Any? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func enc(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Для сравнения названий: без регистра, «ё», скобок с пометками и знаков.
    static func norm(_ text: String) -> String {
        var out = ""
        var depth = 0
        for c in text.lowercased().replacingOccurrences(of: "ё", with: "е") {
            switch c {
            case "(", "[", "（": depth += 1
            case ")", "]", "）": depth = max(depth - 1, 0)
            default:
                if depth == 0, c.isLetter || c.isNumber { out.append(c) }
            }
        }
        return out
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

    /// Тот же ли это трек: название, хоть один исполнитель и длительность в пределах 6 секунд.
    private static func same(_ track: Track, title: String, artist: String, seconds: Int) -> Bool {
        if title.isEmpty || norm(title) != norm(track.title) { return false }
        let theirs = norm(artist)
        let mine = track.artistList.map { norm($0.name) } + [norm(track.artists)]
        let artistOK = theirs.isEmpty || mine.contains { !$0.isEmpty && (theirs.contains($0) || $0.contains(theirs)) }
        let duration = Int(track.duration)
        return artistOK && (duration == 0 || seconds == 0 || abs(seconds - duration) <= 6)
    }

    private static func firstArtist(_ track: Track) -> String {
        track.artistList.first?.name ?? track.artists
    }

    /// Текст из чужой базы: без строк с авторами.
    private static func external(_ text: String, _ source: String) -> LyricsText {
        let lines = API.parseLRC(text).filter { !isCredit($0.text) }
        return LyricsText(lines: lines.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }, authors: nil, source: source)
    }

    static func synced(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.time != nil }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Текст из LRCLIB: точное совпадение, а нет его — поиск.
    private static func lrclib(_ track: Track) async throws -> LyricsText? {
        let headers = ["Lrclib-Client": "Tune iOS"]
        let artist = firstArtist(track)
        var query = "track_name=\(enc(track.title))&artist_name=\(enc(artist))"
        if !track.albumTitle.isEmpty { query += "&album_name=\(enc(track.albumTitle))" }
        if track.duration > 0 { query += "&duration=\(Int(track.duration))" }
        let exact = try await get("https://lrclib.net/api/get?\(query)", headers: headers) as? [String: Any]
        func pick(_ value: [String: Any]) -> LyricsText? {
            guard let text = string(value["syncedLyrics"]) ?? string(value["plainLyrics"]) else { return nil }
            return external(text, "LRCLIB")
        }
        if let exact, string(exact["syncedLyrics"]) != nil, let found = pick(exact) { return found }
        let list = try await get("https://lrclib.net/api/search?track_name=\(enc(track.title))&artist_name=\(enc(artist))", headers: headers) as? [[String: Any]] ?? []
        let matching = list.filter {
            same(track, title: $0["trackName"] as? String ?? "", artist: $0["artistName"] as? String ?? "", seconds: Int(((($0["duration"] as? NSNumber)?.doubleValue) ?? 0).rounded()))
        }
        let chosen = matching.first { string($0["syncedLyrics"]) != nil } ?? exact ?? matching.first
        return chosen.flatMap(pick)
    }

    /// Синхронный текст из NetEase, если там именно этот трек.
    private static func netease(_ track: Track) async throws -> LyricsText? {
        let headers = ["Referer": "https://music.163.com/"]
        let query = "\(firstArtist(track)) \(track.title)".trimmingCharacters(in: .whitespaces)
        guard let found = try await get("https://music.163.com/api/search/get?s=\(enc(query))&type=1&limit=10", headers: headers) as? [String: Any] else { return nil }
        let songs = ((found["result"] as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        let matching = songs.filter { song in
            let artist = ((song["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: " ")
            // «Miyagi & Andy Panda» у NetEase — один исполнитель, у Яндекса — два.
            return !artist.isEmpty && same(track, title: song["name"] as? String ?? "", artist: artist, seconds: ((song["duration"] as? NSNumber)?.intValue ?? 0) / 1000)
        }
        for song in matching.prefix(3) {
            guard let id = (song["id"] as? NSNumber)?.int64Value else { continue }
            guard let lyric = try await get("https://music.163.com/api/song/lyric?id=\(id)&lv=1", headers: headers) as? [String: Any] else { continue }
            let lrc = ((lyric["lrc"] as? [String: Any])?["lyric"] as? String) ?? ""
            // Хотя бы несколько строк со временем — иначе это пустышка или «纯音乐».
            if lrc.components(separatedBy: .newlines).filter({ $0.hasPrefix("[") && $0.count > 11 }).count >= 4 {
                return external(lrc, "NetEase")
            }
        }
        return nil
    }

    /// Текст трека: Яндекс, LRCLIB и NetEase — в порядке из настроек.
    /// Есть ли смысл открывать текст: у Яндекса он есть или его можно поискать в других базах.
    static func available(_ track: Track) -> Bool {
        track.hasLyrics || (Settings.lyricsExternal && (Settings.lyricsLRCLIB || Settings.lyricsNetEase))
    }

    static func find(_ track: Track, yandex: (String) async throws -> LyricsText) async throws -> LyricsText {
        let empty = LyricsText(lines: [], authors: nil, source: nil)
        let enabled = Settings.lyricsExternal
        var own: LyricsText?
        if track.hasLyrics, !enabled || !Settings.lyricsAlways {
            let found = try await yandex(track.id)
            if !enabled || found.synced { return found }
            own = found
        }
        guard enabled else { return empty }
        typealias Search = (Track) async throws -> LyricsText?
        let lrc: (Bool, Search) = (Settings.lyricsLRCLIB, lrclib)
        let net: (Bool, Search) = (Settings.lyricsNetEase, netease)
        let order = Settings.lyricsNetEaseFirst ? [net, lrc] : [lrc, net]
        var fallback: LyricsText?
        for (on, search) in order where on {
            // Чужая база не ответила — не беда, есть другие.
            guard let found = try? await search(track), !found.lines.isEmpty else { continue }
            if found.synced { return found }
            if fallback == nil { fallback = found }
        }
        // Синхронного нет нигде — текст Яндекса, хоть и простой, лучше простого из LRCLIB.
        if track.hasLyrics {
            let mine: LyricsText
            if let own { mine = own } else { mine = try await yandex(track.id) }
            if !mine.lines.isEmpty { return mine }
        }
        return fallback ?? empty
    }
}
