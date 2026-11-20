import Foundation

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}

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
        await testFindPriorityAndConcurrency()
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

    private static func testFindPriorityAndConcurrency() async {
        let syncedYandex = LyricsText(lines: [LyricLine(id: 0, time: 1, text: "Яндекс строка")], authors: nil, source: LyricsText.yandex)
        let plainYandex = LyricsText(lines: [LyricLine(id: 0, time: nil, text: "Обычный текст")], authors: nil, source: LyricsText.yandex)
        let syncedLRCLIB = LyricsText(lines: [LyricLine(id: 0, time: 1, text: "LRCLIB строка")], authors: nil, source: "LRCLIB")
        let syncedNetEase = LyricsText(lines: [LyricLine(id: 0, time: 1, text: "NetEase строка")], authors: nil, source: "NetEase")
        let empty = LyricsText(lines: [], authors: nil, source: nil)

        do {
            let track = makeTrack(title: "T1", artists: "A1", hasLyrics: true)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: true, mirror: "")
            let (res, complete) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in syncedYandex },
                lrclib: { _ in syncedLRCLIB },
                netease: { _ in syncedNetEase }
            )
            assertCheck(res.source == LyricsText.yandex && complete, "Yandex should win when it responds within the grace window")
        }

        // 2. hasLyrics=false -> Yandex is STILL checked; if empty, falls back to external.
        do {
            let yandexCalls = Counter()
            let track = makeTrack(title: "T2", artists: "A2", hasLyrics: false)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: false, mirror: "")
            let (res1, _) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in yandexCalls.increment(); return syncedYandex },
                lrclib: { _ in try? await Task.sleep(nanoseconds: 50_000_000); return syncedLRCLIB },
                netease: { _ in try? await Task.sleep(nanoseconds: 50_000_000); return syncedNetEase }
            )
            assertCheck(yandexCalls.value == 1 && res1.source == LyricsText.yandex, "Yandex must still be queried when hasLyrics == false")

            let (res2, _) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in empty },
                lrclib: { _ in try? await Task.sleep(nanoseconds: 20_000_000); return syncedLRCLIB },
                netease: { _ in try? await Task.sleep(nanoseconds: 80_000_000); return syncedNetEase }
            )
            assertCheck(res2.source == "LRCLIB", "When neteaseFirst=false and Yandex empty, LRCLIB should win")
        }

        // 3. neteaseFirst=true with faster LRCLIB -> waits for NetEase and returns NetEase.
        do {
            let track = makeTrack(title: "T3", artists: "A3", hasLyrics: false)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: true, mirror: "")
            let (res, complete) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in empty },
                lrclib: { _ in try? await Task.sleep(nanoseconds: 10_000_000); return syncedLRCLIB },
                netease: { _ in try? await Task.sleep(nanoseconds: 80_000_000); return syncedNetEase }
            )
            assertCheck(res.source == "NetEase" && complete, "neteaseFirst=true must wait for higher-priority NetEase")
        }

        // 4. neteaseFirst=true with faster LRCLIB and empty NetEase -> falls back to LRCLIB.
        do {
            let track = makeTrack(title: "T4", artists: "A4", hasLyrics: false)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: true, mirror: "")
            let (res, complete) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in empty },
                lrclib: { _ in try? await Task.sleep(nanoseconds: 10_000_000); return syncedLRCLIB },
                netease: { _ in try? await Task.sleep(nanoseconds: 60_000_000); return nil }
            )
            assertCheck(res.source == "LRCLIB" && complete, "neteaseFirst=true should fall back to LRCLIB when NetEase has nothing")
        }

        // 5. always=true -> prefers external synced over fast Yandex synced; falls back to Yandex synced if external has nothing.
        do {
            let track = makeTrack(title: "T5", artists: "A5", hasLyrics: true)
            let opts = ExternalLyrics.Options(external: true, always: true, lrclib: true, netease: true, neteaseFirst: false, mirror: "")
            let (res1, _) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in syncedYandex },
                lrclib: { _ in try? await Task.sleep(nanoseconds: 40_000_000); return nil },
                netease: { _ in try? await Task.sleep(nanoseconds: 350_000_000); return syncedNetEase }
            )
            assertCheck(res1.source == "NetEase", "always=true must prefer external synced over Yandex synced")

            let (res2, _) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in syncedYandex },
                lrclib: { _ in nil },
                netease: { _ in nil }
            )
            assertCheck(res2.source == LyricsText.yandex, "always=true must fall back to Yandex synced when external has nothing")
        }

        // 6. Private (UGC) track -> never calls Yandex, still finds external lyrics.
        do {
            let yandexCalls = Counter()
            let track = makeTrack(id: "ugc-123", title: "Private", artists: "Singer", hasLyrics: false, ugc: true)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: false, mirror: "")
            let (res, complete) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in yandexCalls.increment(); return plainYandex },
                lrclib: { _ in syncedLRCLIB },
                netease: { _ in nil }
            )
            assertCheck(yandexCalls.value == 0 && res.source == "LRCLIB" && complete, "Private track must skip Yandex and use external")
        }

        // 7. Yandex subscription stub filtered out.
        do {
            let stub = LyricsText(lines: [LyricLine(id: 0, time: nil, text: "Текст доступен по подписке")], authors: nil, source: LyricsText.yandex)
            let track = makeTrack(title: "T7", artists: "A7", hasLyrics: true)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: false, netease: true, neteaseFirst: false, mirror: "")
            let (res, complete) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in stub },
                lrclib: { _ in nil },
                netease: { _ in syncedNetEase }
            )
            assertCheck(res.source == "NetEase" && complete, "Subscription stub must be ignored in favor of NetEase")
        }

        do {
            let track = makeTrack(title: "T8", artists: "A8", hasLyrics: true)
            let opts = ExternalLyrics.Options(external: true, always: false, lrclib: false, netease: true, neteaseFirst: true, mirror: "")
            let canceled = Counter()
            let (res, complete) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in
                    do {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        return syncedYandex
                    } catch {
                        canceled.increment()
                        throw error
                    }
                },
                netease: { _ in syncedNetEase }
            )
            assertCheck(res.source == "NetEase" && !complete && canceled.value == 1, "A slow Yandex response must not block NetEase or make the fallback final")

            let (fallback, definitive) = await ExternalLyrics.find(
                track, options: opts,
                yandex: { _ in throw URLError(.timedOut) },
                netease: { _ in syncedNetEase }
            )
            assertCheck(fallback.source == "NetEase" && !definitive, "Failure of the preferred provider must leave the fallback open to retry")
        }
    }

    private static func testExternalProviderFallbacks() async throws {
        let track = makeTrack(title: "Test Song", artists: "Test Artist")
        let netease = try await ExternalLyrics.fetchNetEase(track) { request in
            let url = request.url!
            switch url.host {
            case "music.163.com":
                throw URLError(.timedOut)
            case "interface.music.163.com":
                return response(url, #"{"code":200,"result":{"songs":[]}}"#)
            default:
                if url.path == "/api/search/get" {
                    return response(url, #"{"code":200,"result":{"songs":[{"id":1,"name":"Test Song","artists":[{"name":"Test Artist"}]},{"id":"2","name":"Test Song","artists":[{"name":"Test Artist"}]}]}}"#)
                }
                if url.query?.contains("id=1") == true { throw URLError(.badServerResponse) }
                return response(url, #"{"code":200,"lrc":{"lyric":"[00:01]One\n[00:02]Two\n[00:03]Three\n[00:04]Four"}}"#)
            }
        }
        assertCheck(netease?.source == "NetEase" && netease?.lines.count == 4, "An empty host, a failed host and a failed first song must not hide a valid result")

        let lrclib = try await ExternalLyrics.fetchLRCLIB(track, mirrorText: "mirror.example") { request in
            let url = request.url!
            if url.host == "mirror.example" || url.path == "/api/get" { throw URLError(.timedOut) }
            return response(url, #"[{"trackName":"Test Song","artistName":"Test Artist","duration":200,"syncedLyrics":"[00:01]One"}]"#)
        }
        assertCheck(lrclib?.source == "LRCLIB" && lrclib?.synced == true, "A failed mirror and exact request must not prevent LRCLIB search")

        let plain = try await ExternalLyrics.fetchLRCLIB(track, mirrorText: "") { request in
            let url = request.url!
            if url.path == "/api/search" { throw URLError(.timedOut) }
            return response(url, #"{"plainLyrics":"Available text"}"#)
        }
        assertCheck(plain?.lines.first?.text == "Available text", "Search failure must not discard plain LRCLIB lyrics")

        let pirate = makeTrack(title: "Почему ты ещё не фанат?", artists: "Серёга Пират", durationMs: 163_711)
        let pirateLyrics = try await ExternalLyrics.fetchLRCLIB(pirate, mirrorText: "") { request in
            let url = request.url!
            assertCheck(request.timeoutInterval > 6, "LRCLIB needs a longer timeout")
            assertCheck(request.value(forHTTPHeaderField: "User-Agent")?.contains("github.com/tune-music/tune-ios") == true, "LRCLIB requires client identification")
            if url.path == "/api/get" { throw URLError(.timedOut) }
            let artist = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "artist_name" }?.value
            if artist != "Серега Пират" { return response(url, "[]") }
            return response(url, #"[{"trackName":"Почему ты еще не фанат?","artistName":"СЕРЕГА ПИРАТ","duration":164,"syncedLyrics":"[00:01]Match"}]"#)
        }
        assertCheck(pirateLyrics?.synced == true, "LRCLIB must retry with folded Russian metadata")
    }

    private static func response(_ url: URL, _ body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
