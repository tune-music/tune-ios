import Foundation

private func assertCheck(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
        exit(1)
    }
}

private func makeTrack(
    id: String = "100",
    title: String,
    version: String? = nil,
    artists: String,
    artistList: [ArtistRef]? = nil,
    durationMs: Int = 200_000,
    hasLyrics: Bool = false,
    ugc: Bool? = false
) -> Track {
    let refs = artistList ?? artists.split(separator: ",").enumerated().map {
        ArtistRef(id: "\($0.offset + 1)", name: $0.element.trimmingCharacters(in: .whitespaces))
    }
    return Track(
        id: id,
        title: title,
        version: version,
        artists: artists,
        artistList: refs,
        durationMs: durationMs,
        cover: nil,
        albumId: "1",
        albumTitle: "Album",
        explicit: false,
        hasLyrics: hasLyrics,
        unavailable: false,
        uncensored: false,
        batch: nil,
        loudness: nil,
        peak: nil,
        fade: nil,
        mixFade: nil,
        ugc: ugc
    )
}

@main
struct LyricsTests {
    static func main() async throws {
        testParseLRC()
        testMatching()
        testHelpers()
        await testProviderOrder()
        try await testExternalProviderFallbacks()
        testAcceptCachedPolicy()
        print("Lyrics unit checks passed")

        if CommandLine.arguments.contains("--live") {
            try await testLiveNetEase()
            print("Live NetEase checks passed")
        }
    }

    private static func testParseLRC() {
        let multi = "[ar:Artist]\r\n[ti:Song]\r\n[00:10.00][01:00.50]Припев\r\n[00:05,25]Начало\r\n[00:12.00]\r\n"
        let parsed = ExternalLyrics.parseLRC(multi)
        assertCheck(parsed.count == 4, "Expected 4 lines, got \(parsed.count)")
        assertCheck(parsed.map(\.id) == [0, 1, 2, 3], "Sequential IDs expected")
        assertCheck(abs((parsed[0].time ?? -1) - 5.25) < 0.001 && parsed[0].text == "Начало", "Comma seconds & sorting failed")
        assertCheck(abs((parsed[1].time ?? -1) - 10.0) < 0.001 && parsed[1].text == "Припев", "First multi-tag failed")
        assertCheck(abs((parsed[2].time ?? -1) - 12.0) < 0.001 && parsed[2].text.isEmpty, "Empty timed interlude line must be preserved")
        assertCheck(abs((parsed[3].time ?? -1) - 60.5) < 0.001 && parsed[3].text == "Припев", "Second multi-tag failed")

        let withOffset = "[offset:-2000]\n[00:01.00]Early\n[00:05.50]Later"
        let shifted = ExternalLyrics.parseLRC(withOffset)
        assertCheck(shifted.count == 2, "Expected 2 shifted lines")
        assertCheck(abs((shifted[0].time ?? -1) - 0.0) < 0.001, "Negative offset should clamp at 0")
        assertCheck(abs((shifted[1].time ?? -1) - 3.5) < 0.001, "Offset -2000ms should shift 5.5s -> 3.5s")

        let plain = ExternalLyrics.parseLRC("First plain line\n\nSecond plain line")
        assertCheck(plain.count == 2 && plain.allSatisfy { $0.time == nil }, "Plain lines should stay untimed")
        assertCheck(plain.map(\.text) == ["First plain line", "Second plain line"], "Plain lines order mismatch")
    }

    private static func testMatching() {
        let yoTrack = makeTrack(title: "Ёлки-палки!", artists: "Тест", durationMs: 200_000)
        assertCheck(ExternalLyrics.matches(yoTrack, lyricHit: ("Елки палки", "Тест", 200)), "yo/ye equivalence failed")
        assertCheck(ExternalLyrics.matches(yoTrack, lyricHit: ("Елки палки", "Тест", 207)), "7s duration delta should match within 8s")
        assertCheck(ExternalLyrics.matches(yoTrack, lyricHit: ("Елки палки", "Тест", 192)), "8s duration delta should match")
        assertCheck(!ExternalLyrics.matches(yoTrack, lyricHit: ("Елки палки", "Тест", 210)), "10s duration delta should not match")

        let parensTrack = makeTrack(title: "(Nice Dream)", artists: "Radiohead", durationMs: 233_000)
        assertCheck(ExternalLyrics.matches(parensTrack, lyricHit: ("Nice Dream", "Radiohead", 233)), "Parenthesized track title should match plain")
        assertCheck(ExternalLyrics.matches(parensTrack, lyricHit: ("(Nice Dream)", "Radiohead", 233)), "Parenthesized track title should match exact")
        assertCheck(!ExternalLyrics.matches(parensTrack, lyricHit: ("(Other Song)", "Radiohead", 233)), "Parenthesized title must not false-match another parenthesized title")

        let versionTrack = makeTrack(title: "Песня", version: "Remix", artists: "Артист", durationMs: 180_000)
        assertCheck(ExternalLyrics.matches(versionTrack, lyricHit: ("Песня (Remix)", "Артист", 180)), "fullTitle version should match")
        assertCheck(ExternalLyrics.matches(versionTrack, lyricHit: ("Песня", "Артист", 180)), "base title should match")

        let duoTrack = makeTrack(title: "Captain", artists: "Miyagi, Andy Panda", durationMs: 214_000)
        assertCheck(ExternalLyrics.matches(duoTrack, lyricHit: ("Captain", "Miyagi & Andy Panda", 214)), "Combined NetEase artist string should match")
        assertCheck(ExternalLyrics.matches(duoTrack, lyricHit: ("Captain", "MiyaGi", 214)), "Single artist match failed")
        assertCheck(!ExternalLyrics.matches(duoTrack, lyricHit: ("Captain", "Other Artist", 214)), "Wrong artist must not match")

        let shortArtistTrack = makeTrack(title: "Gucci Gang", artists: "Lil Pump", durationMs: 124_000)
        assertCheck(!ExternalLyrics.matches(shortArtistTrack, lyricHit: ("Gucci Gang", "Li", 124)), "Short substring artist must not false-match")
    }

    private static func testHelpers() {
        assertCheck(ExternalLyrics.isCredit("作词 : Азамат Кудзаев"), "Chinese credit should be filtered")
        assertCheck(ExternalLyrics.isCredit("Lyrics by: Test"), "English credit with colon should be filtered")
        assertCheck(!ExternalLyrics.isCredit("Lyrics by the river"), "Normal lyric without colon must stay")
        assertCheck(ExternalLyrics.isCredit("Автор текста: Иван"), "Russian credit should be filtered")
        assertCheck(!ExternalLyrics.isCredit("Я сказал: привет"), "Regular lyric line with colon should stay")
        assertCheck(!ExternalLyrics.isCredit("20:00 на часах"), "Time-like text should stay")

        let stub = [LyricLine(id: 0, time: nil, text: "Текст доступен по подписке Яндекс Плюс")]
        assertCheck(ExternalLyrics.isStub(stub), "Subscription stub must be detected")
        assertCheck(ExternalLyrics.filterYandex(stub).isEmpty, "Yandex stub line must be filtered")

        let normalSongWithWord = (0..<6).map { LyricLine(id: $0, time: Double($0), text: $0 == 0 ? "Подписка на жизнь" : "Строка \($0)") }
        assertCheck(!ExternalLyrics.isStub(normalSongWithWord), "6-line real lyrics should not be treated as stub")

        assertCheck(ExternalLyrics.mirror("lrclib.example.com/") == "https://lrclib.example.com", "Mirror should add https and trim slash")
        assertCheck(ExternalLyrics.mirror("https://lrclib.example.com/custom") == "https://lrclib.example.com/custom", "Mirror path should be preserved")
        assertCheck(ExternalLyrics.mirror("http://lrclib.example.com") == nil, "HTTP mirror must be rejected")
        assertCheck(ExternalLyrics.mirror("https://user:pass@lrclib.example.com") == nil, "Userinfo in mirror must be rejected")
        assertCheck(ExternalLyrics.mirror("https://lrclib.example.com?q=1") == nil, "Query in mirror must be rejected")
        assertCheck(ExternalLyrics.mirror("https://lrclib.example.com#frag") == nil, "Fragment in mirror must be rejected")
        assertCheck(ExternalLyrics.mirror("   ") == nil, "Blank mirror must be nil")
    }

    private static func testProviderOrder() async {
        let track = makeTrack(title: "Song", artists: "Artist", hasLyrics: true)
        let synced = LyricsText(lines: [LyricLine(id: 0, time: 1, text: "Synced")], authors: nil, source: nil)
        let plain = LyricsText(lines: [LyricLine(id: 0, time: nil, text: "Plain")], authors: nil, source: nil)
        let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: false, mirror: "")

        var calls: [ExternalLyrics.Source] = []
        let (own, ownComplete) = await ExternalLyrics.find(
            track, options: opts,
            yandex: { _ in calls.append(.yandex); return synced },
            lrclib: { _ in calls.append(.lrclib); return nil },
            netease: { _ in calls.append(.netease); return nil }
        )
        assertCheck(ownComplete && own.source == LyricsText.yandex && calls == [.yandex], "Yandex synced text must stop external requests")

        calls = []
        let (external, complete) = await ExternalLyrics.find(
            track, options: opts,
            yandex: { _ in calls.append(.yandex); throw URLError(.timedOut) },
            lrclib: { _ in
                calls.append(.lrclib)
                return LyricsText(lines: synced.lines, authors: nil, source: "LRCLIB")
            },
            netease: { _ in calls.append(.netease); return nil }
        )
        assertCheck(complete && external.source == "LRCLIB" && calls == [.yandex, .lrclib], "A timed out provider must not block or invalidate a usable fallback")

        calls = []
        var preferred = opts
        preferred.always = true
        preferred.neteaseFirst = true
        let (first, _) = await ExternalLyrics.find(
            track, options: preferred,
            yandex: { _ in calls.append(.yandex); return synced },
            lrclib: { _ in calls.append(.lrclib); return nil },
            netease: { _ in
                calls.append(.netease)
                return LyricsText(lines: synced.lines, authors: nil, source: "NetEase")
            }
        )
        assertCheck(first.source == "NetEase" && calls == [.yandex, .netease], "NetEase first must preserve Yandex as fallback")

        let (fallback, fallbackComplete) = await ExternalLyrics.find(
            track, options: preferred,
            yandex: { _ in plain },
            lrclib: { _ in throw URLError(.timedOut) },
            netease: { _ in nil }
        )
        assertCheck(fallbackComplete && fallback.source == LyricsText.yandex && !fallback.synced, "Plain text must remain usable after an external failure")

        let privateTrack = makeTrack(title: "Upload", artists: "Artist", ugc: true)
        let (missing, missingComplete) = await ExternalLyrics.find(
            privateTrack, options: opts,
            yandex: { _ in assertCheck(false, "Do not ask Yandex for private tracks"); return synced },
            lrclib: { _ in throw URLError(.timedOut) },
            netease: { _ in nil }
        )
        assertCheck(missing.lines.isEmpty && !missingComplete, "A network failure without lyrics must remain retryable")
    }

    private static func testExternalProviderFallbacks() async throws {
        let track = makeTrack(title: "Почему ты еще не фанат?", artists: "Серега Пират", durationMs: 163_711)
        let lrclib = try await ExternalLyrics.fetchLRCLIB(track, mirrorText: "mirror.example") { request in
            let url = request.url!
            assertCheck(request.timeoutInterval == 6, "Use the Android read timeout")
            assertCheck(url.query?.contains("+") == true, "Use Android form encoding for spaces")
            assertCheck(request.value(forHTTPHeaderField: "User-Agent")?.contains("github.com/tune-music/tune-ios") == true, "Identify the LRCLIB client")
            if url.host == "mirror.example" { throw URLError(.timedOut) }
            if url.path == "/api/get" { return response(url, "{}", status: 404) }
            return response(url, #"[{"trackName":"Почему ты еще не фанат?","artistName":"СЕРЕГА ПИРАТ","duration":164,"syncedLyrics":"[00:01]Match"}]"#)
        }
        assertCheck(lrclib?.source == "LRCLIB" && lrclib?.synced == true, "An unavailable mirror and an exact miss must fall back to search")

        let plain = try await ExternalLyrics.fetchLRCLIB(track, mirrorText: "") { request in
            let url = request.url!
            if url.path == "/api/search" { throw URLError(.timedOut) }
            return response(url, #"{"plainLyrics":"Available text"}"#)
        }
        assertCheck(plain?.lines.first?.text == "Available text", "Search failure must not discard available plain lyrics")

        let netease = try await ExternalLyrics.fetchNetEase(track) { request in
            let url = request.url!
            assertCheck(request.value(forHTTPHeaderField: "Referer") == "https://music.163.com/", "Send the same Referer as Android")
            if url.host == "music.163.com" { return response(url, "{}", status: 403) }
            assertCheck(url.host == "interface.music.163.com", "Try the next endpoint in order")
            if url.path == "/api/search/get" {
                return response(url, #"{"code":200,"result":{"songs":[{"id":1,"name":"Почему ты еще не фанат?","artists":[{"name":"Серега Пират"}]},{"id":"2","name":"Почему ты еще не фанат?","artists":[{"name":"Серега Пират"}]}]}}"#)
            }
            if url.query?.contains("id=1") == true { return response(url, "{}") }
            return response(url, #"{"code":200,"lrc":{"lyric":"[00:01]One\n[00:02]Two\n[00:03]Three\n[00:04]Four"}}"#)
        }
        assertCheck(netease?.source == "NetEase" && netease?.lines.count == 4, "Try another address or candidate without restarting the search")
    }

    private static func response(_ url: URL, _ body: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private static func testAcceptCachedPolicy() {
        let opts1 = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: false, mirror: "")
        let opts2 = ExternalLyrics.Options(external: true, always: true, lrclib: true, netease: true, neteaseFirst: true, mirror: "")
        let key1 = ExternalLyrics.settingsKey(for: opts1)

        let saved = LyricsText(
            lines: [LyricLine(id: 0, time: 1.5, text: "Line")],
            authors: nil,
            source: "NetEase",
            searched: key1
        )
        assertCheck(ExternalLyrics.acceptCached(saved, options: opts1, anySource: false) != nil, "Matching settings cache must be accepted")
        assertCheck(ExternalLyrics.acceptCached(saved, options: opts2, anySource: false) == nil, "Mismatched settings cache must be rejected online")
        assertCheck(ExternalLyrics.acceptCached(saved, options: opts2, anySource: true) != nil, "Mismatched settings cache MUST be accepted offline")

        var partial = saved
        partial.searched = "partial:\(key1)"
        assertCheck(ExternalLyrics.acceptCached(partial, options: opts1, anySource: false) == nil, "Partial cache must not suppress a new online attempt")
        assertCheck(ExternalLyrics.acceptCached(partial, options: opts1, anySource: true) != nil, "Partial cache must remain available offline")

        let legacyNetEase = LyricsText(lines: [LyricLine(id: 0, time: 1.0, text: "Old")], authors: nil, source: "NetEase", searched: nil)
        let noNetEase = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: false, neteaseFirst: false, mirror: "")
        assertCheck(ExternalLyrics.acceptCached(legacyNetEase, options: noNetEase, anySource: false) == nil, "Legacy NetEase cache rejected online when disabled")
        assertCheck(ExternalLyrics.acceptCached(legacyNetEase, options: noNetEase, anySource: true) != nil, "Legacy NetEase cache accepted offline even when disabled")

        let stub = LyricsText(lines: [LyricLine(id: 0, time: nil, text: "Текст доступен по подписке")], authors: nil, source: LyricsText.yandex, searched: key1)
        assertCheck(ExternalLyrics.acceptCached(stub, options: opts1, anySource: true) == nil, "Stub cache must always be rejected")
    }

    private static func testLiveNetEase() async throws {
        let tracks = [
            makeTrack(id: "live-1", title: "Captain", artists: "Miyagi", durationMs: 214_000),
            makeTrack(id: "live-2", title: "Группа крови", artists: "Кино", durationMs: 284_000),
            makeTrack(id: "live-3", title: "Цепи", artists: "Скриптонит", durationMs: 207_000),
            makeTrack(id: "live-4", title: "Nothing Else Matters", artists: "Metallica", durationMs: 388_000),
        ]
        for track in tracks {
            let t0 = Date()
            let res = try await ExternalLyrics.fetchNetEase(track)
            let dt = String(format: "%.2fs", Date().timeIntervalSince(t0))
            assertCheck(res != nil, "Live NetEase returned nil for \(track.artists) - \(track.title)")
            assertCheck(res?.synced == true, "Live NetEase must return synced lyrics for \(track.title)")
            assertCheck((res?.lines.count ?? 0) >= 10, "Live NetEase returned too few lines for \(track.title)")
            let sample = res?.lines.first?.text ?? ""
            print("  Live NetEase OK (\(dt)): \(track.artists) - \(track.title) [\(res?.lines.count ?? 0) lines, first: \(sample)]")
        }
    }
}
