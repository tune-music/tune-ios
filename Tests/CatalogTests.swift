import Foundation

private func assertCheck(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() {
        fputs("FAIL (\(file):\(line)): \(message)\n", stderr)
        exit(1)
    }
}

@main
struct CatalogTests {
    static func main() async throws {
        testSyntheticIDs()
        testCoverURL()
        testSettingsDefaultAndToggle()
        testCatalogMergeSearchAndBadgeRules()
        try testCatalogLibraryRoundtrip()
        testCatalogLibraryStoreVisibilityAndPreservation()
        try testTrackCodableBackwardCompatibility()
        await testExternalLyricsSkipsYandexForSyntheticTrack()
        print("Catalog unit checks passed")
    }

    private static func testSyntheticIDs() {
        assertCheck(TuneCatalogID.isSyntheticTrack("9000000001"), "9000000001 must be synthetic track")
        assertCheck(TuneCatalogID.isSyntheticTrack("9000000123"), "64-bit synthetic track ID must parse")
        assertCheck(!TuneCatalogID.isSyntheticTrack("9000000000"), "Boundary 9000000000 is not synthetic track")
        assertCheck(!TuneCatalogID.isSyntheticTrack("123456"), "Regular Yandex track is not synthetic")
        assertCheck(!TuneCatalogID.isSyntheticTrack("ugc-1"), "UGC ID is not synthetic")

        assertCheck(TuneCatalogID.isSyntheticAlbum("900000001"), "900000001 must be synthetic album")
        assertCheck(!TuneCatalogID.isSyntheticAlbum("900000000"), "Boundary 900000000 is not synthetic album")
        assertCheck(!TuneCatalogID.isSyntheticAlbum("9000000001"), "Track ID must not be synthetic album")

        assertCheck(TuneCatalogID.isSyntheticArtist("90000001"), "90000001 must be synthetic artist")
        assertCheck(!TuneCatalogID.isSyntheticArtist("90000000"), "Boundary 90000000 is not synthetic artist")
        assertCheck(!TuneCatalogID.isSyntheticArtist("900000001"), "Album ID must not be synthetic artist")

        assertCheck(TuneCatalogID.isSyntheticPlaylist("9000001"), "9000001 must be synthetic playlist")
        assertCheck(!TuneCatalogID.isSyntheticPlaylist("9000000"), "Boundary 9000000 is not synthetic playlist")
    }

    private static func testCoverURL() {
        let direct = "https://github.com/tune-music/tune-catalog-data/releases/download/c/cover.jpg"
        assertCheck(Cover.url(direct, side: 400)?.absoluteString == direct, "Full https URL must not be mangled")

        let httpDirect = "http://example.com/cover.png"
        assertCheck(Cover.url(httpDirect, side: 200)?.absoluteString == httpDirect, "Full http URL must not be mangled")

        let yandexTemplate = "avatars.yandex.net/get-music-content/123/abc/%%"
        assertCheck(
            Cover.url(yandexTemplate, side: 400)?.absoluteString == "https://avatars.yandex.net/get-music-content/123/abc/400x400",
            "Yandex template without scheme must expand %% and prepend https://"
        )

        let yandexFull = "https://avatars.yandex.net/get-music-content/123/abc/%%"
        assertCheck(
            Cover.url(yandexFull, side: 800)?.absoluteString == "https://avatars.yandex.net/get-music-content/123/abc/800x800",
            "Yandex template with https:// must expand %%"
        )

        let protocolRelative = "//avatars.yandex.net/get-music-content/123/abc/%%"
        assertCheck(
            Cover.url(protocolRelative, side: 200)?.absoluteString == "https://avatars.yandex.net/get-music-content/123/abc/200x200",
            "Protocol-relative URI must prepend https:"
        )

        assertCheck(Cover.url(nil, side: 200) == nil, "nil cover must return nil")
        assertCheck(Cover.url("   ", side: 200) == nil, "Blank cover must return nil")
    }

    private static func testSettingsDefaultAndToggle() {
        let defaults = UserDefaults.standard
        let hadKey = defaults.object(forKey: "catalog")
        defer {
            if let hadKey {
                defaults.set(hadKey, forKey: "catalog")
            } else {
                defaults.removeObject(forKey: "catalog")
            }
        }

        defaults.removeObject(forKey: "catalog")
        assertCheck(Settings.catalog == true, "Settings.catalog must default to true")
        Settings.catalog = false
        assertCheck(Settings.catalog == false, "Settings.catalog must persist false")
        Settings.catalog = true
        assertCheck(Settings.catalog == true, "Settings.catalog must persist true")
    }

    private static func testCatalogMergeSearchAndBadgeRules() {
        let fckRoot: [String: Any] = [
            "sources": [[
                "tracks": [
                    "1": ["title": "Из Fck"],
                    "2": ["title": "Только Fck"]
                ],
                "tracksStorages": [[
                    "urlTemplate": "https://fck.org/%%.mp3",
                    "trackIds": [1, 2]
                ]]
            ]]
        ]

        let catalogRoot: [String: Any] = [
            "sources": [[
                "tracks": [
                    "1": ["title": "Из Tune"],
                    "555": ["title": "Родной трек в дополненном альбоме"],
                    "9000000001": [
                        "title": "Камен",
                        "artists": [["id": 90000001, "name": "Ёжик"]],
                        "durationMs": 186000
                    ]
                ],
                "albums": [
                    "900000001": [
                        "title": "Первый альбом",
                        "coverUri": "https://cdn.example.org/album.jpg",
                        "artists": [["id": 90000001, "name": "Ёжик"]],
                        "volumes": [["555", "9000000001"]]
                    ]
                ],
                "artists": [
                    "90000001": ["name": "Ёжик", "description": "Инди"]
                ],
                "playlists": [
                    "9000001": [
                        "title": "Подборка дня",
                        "coverUri": "https://cdn.example.org/playlist.jpg",
                        "tracks": ["9000000001"]
                    ]
                ],
                "artistsInsertions": [
                    "90000001": ["tracks": ["9000000001"], "albums": ["900000001"]],
                    "100": ["tracks": ["9000000001"], "albums": ["900000001"]]
                ],
                "tracksStorages": [[
                    "urlTemplate": "https://github.com/tune-music/tune-catalog-data/releases/download/audio-1/%%.mp3",
                    "tracks": [
                        "1": ["url": "1", "durationMs": 1000],
                        "9000000001": ["url": "9000000001", "durationMs": 186000]
                    ]
                ]]
            ]]
        ]

        let merged = CatalogIndex.parseMerged(catalog: catalogRoot, fck: fckRoot)
        assertCheck(merged.tracks["1"]?["title"] as? String == "Из Tune", "Catalog metadata must override FckCensor")
        assertCheck(
            merged.files["1"] == "https://github.com/tune-music/tune-catalog-data/releases/download/audio-1/1.mp3",
            "Catalog audio stream must override FckCensor"
        )
        assertCheck(merged.files["2"] == "https://fck.org/2.mp3", "FckCensor-only audio must stay available")
        assertCheck(merged.files["555"] == nil, "Track 555 without storage must have no file")
        assertCheck(
            merged.tracks["9000000001"]?["coverUri"] as? String == "https://cdn.example.org/album.jpg",
            "Catalog track without coverUri must inherit full https album cover"
        )
        assertCheck(
            merged.inserts["100"]?.tracks == ["9000000001"] && merged.inserts["100"]?.albums == ["900000001"],
            "artistsInsertions must preserve synthetic track and album IDs"
        )

        let state = CatalogState()
        let initialVersion = state.version
        state.setFck(fckRoot)
        state.setCatalog(catalogRoot)
        assertCheck(state.version > initialVersion, "CatalogState version must increment on updates")

        // Критичное правило значков: «T» — только при наличии файла в catalogList.files,
        // замок — только у FckCensor и НЕ у треков каталога Tune.
        assertCheck(state.isCatalogTrack("9000000001", catalogEnabled: true), "Synthetic catalog track with file must be catalog track")
        assertCheck(!state.hasFckCensor("9000000001", uncensorEnabled: true, catalogEnabled: true), "Catalog track must not have FckCensor badge")
        assertCheck(state.isCatalogTrack("1", catalogEnabled: true), "Overridden track in catalog files must have T badge")
        assertCheck(!state.hasFckCensor("1", uncensorEnabled: true, catalogEnabled: true), "FckCensor badge must exclude catalog tracks")
        assertCheck(!state.isCatalogTrack("555", catalogEnabled: true), "Native Yandex track in supplemented album must NOT get T badge")
        assertCheck(!state.hasFckCensor("555", uncensorEnabled: true, catalogEnabled: true), "Track 555 must not get FckCensor badge")
        assertCheck(!state.isCatalogTrack("2", catalogEnabled: true), "FckCensor-only track must not get T badge")
        assertCheck(state.hasFckCensor("2", uncensorEnabled: true, catalogEnabled: true), "FckCensor-only track must get FckCensor badge")

        // Поиск по каталогу (треки, альбомы, исполнители, плейлисты) при включенном каталоге.
        let hits = state.search("камен", tracks: true, albums: true, artists: true, playlists: true, uncensorEnabled: true, catalogEnabled: true)
        assertCheck(hits.tracks.count == 1 && hits.tracks[0]["id"].idText == "9000000001", "Track search must find synthetic track")
        assertCheck(state.search("ежик", tracks: true, albums: true, artists: true, playlists: true, uncensorEnabled: true, catalogEnabled: true).artists.count == 1, "Artist search must find synthetic artist")
        assertCheck(state.search("первый", tracks: true, albums: true, artists: true, playlists: true, uncensorEnabled: true, catalogEnabled: true).albums.count == 1, "Album search must find synthetic album")
        assertCheck(state.search("подборка", tracks: true, albums: true, artists: true, playlists: true, uncensorEnabled: true, catalogEnabled: true).playlists.count == 1, "Playlist search must find synthetic playlist")

        // Независимые переключатели: Каталог выключен, Без цензуры включено.
        assertCheck(!state.isCatalogTrack("1", catalogEnabled: false), "T badge must turn off when catalog is disabled")
        assertCheck(state.hasFckCensor("1", uncensorEnabled: true, catalogEnabled: false), "FckCensor badge must appear for shared track when catalog is disabled")
        let disabledHits = state.search("камен", tracks: true, albums: true, artists: true, playlists: true, uncensorEnabled: true, catalogEnabled: false)
        assertCheck(disabledHits.tracks.isEmpty && disabledHits.artists.isEmpty && disabledHits.playlists.isEmpty, "Catalog search must be empty when catalog is disabled")

        // Независимые переключатели: Без цензуры выключено, Каталог включён.
        assertCheck(state.isCatalogTrack("1", catalogEnabled: true), "Catalog track must stay enabled when uncensor is off")
        assertCheck(!state.hasFckCensor("2", uncensorEnabled: false, catalogEnabled: true), "FckCensor track must be hidden when uncensor is off")
        assertCheck(state.search("камен", tracks: true, albums: true, artists: true, playlists: true, uncensorEnabled: false, catalogEnabled: true).tracks.count == 1, "Catalog search must still work when uncensor is off")

        // Обе настройки выключены.
        assertCheck(state.current(uncensorEnabled: false, catalogEnabled: false) == nil, "Merged list must be nil when both toggles are off")

        // Синтетический исполнитель и плейлист.
        let artist = state.catalogArtist("90000001", uncensorEnabled: true, catalogEnabled: true)
        assertCheck(artist?.json["name"].string == "Ёжик", "Synthetic artist name mismatch")
        assertCheck(artist?.trackIDs == ["9000000001"], "Synthetic artist tracks mismatch")
        assertCheck(artist?.albumIDs == ["900000001"], "Synthetic artist albums mismatch")

        let playlist = state.catalogPlaylist("9000001", catalogEnabled: true)
        assertCheck(playlist?.trackIDs == ["9000000001"], "Synthetic playlist tracks mismatch")

        // Дополненный альбом Яндекса: проверка порядка volumes (родной трек + синтетический)
        // и отсутствия значка «T» у родного трека Яндекса внутри того же диска.
        let supplementedRoot: [String: Any] = [
            "sources": [[
                "tracks": [
                    "555": ["title": "Родной трек"],
                    "9000000002": ["title": "Доп. трек", "durationMs": 120000]
                ],
                "albums": [
                    "777": [
                        "title": "Альбом Яндекса",
                        "volumes": [["555", "9000000002"]]
                    ]
                ],
                "tracksStorages": [[
                    "urlTemplate": "https://cdn.example.org/%%.mp3",
                    "trackIds": ["9000000002"]
                ]]
            ]]
        ]
        let suppState = CatalogState()
        suppState.setCatalog(supplementedRoot)
        let suppAlbum = suppState.catalogAlbum("777", uncensorEnabled: true, catalogEnabled: true)
        let disk = suppAlbum?["volumes"][0].array.compactMap(\.idText) ?? []
        assertCheck(disk == ["555", "9000000002"], "Supplemented album volumes must preserve native + synthetic order")
        assertCheck(!suppState.isCatalogTrack("555", catalogEnabled: true), "Native track inside supplemented album must NOT have T badge")
        assertCheck(suppState.isCatalogTrack("9000000002", catalogEnabled: true), "Inserted catalog track with file must have T badge")
    }

    private static func testCatalogLibraryStoreVisibilityAndPreservation() {
        let defaults = UserDefaults.standard
        let prevCatalog = defaults.object(forKey: "catalog")
        defer {
            if let prevCatalog { defaults.set(prevCatalog, forKey: "catalog") }
            else { defaults.removeObject(forKey: "catalog") }
        }
        let uid = "test-catalog-store-\(UUID().uuidString)"
        let store = CatalogLibraryStore.shared
        store.load(uid: uid)
        defer {
            store.clearInMemory()
            Storage.remove("catalog-library-\(Storage.hash(uid)).json")
        }

        Settings.catalog = true
        store.setTrackLiked("9000000001", true)
        store.setTrackDisliked("9000000002", true)
        store.setAlbumLiked("900000001", true)
        store.setArtistLiked("90000001", true)
        store.setArtistDisliked("90000002", true)
        store.setPlaylistLiked("9000001", true)
        store.addPlaylistTracks(["9000000001"], owner: uid, kind: "10")

        assertCheck(store.likedTracks == ["9000000001"], "Store must return likedTracks when enabled")
        assertCheck(store.playlistTracks(owner: uid, kind: "10") == ["9000000001"], "Store must return playlistTracks when enabled")

        Settings.catalog = false
        assertCheck(store.likedTracks.isEmpty, "Store must hide likedTracks when catalog disabled")
        assertCheck(store.dislikedTracks.isEmpty, "Store must hide dislikedTracks when catalog disabled")
        assertCheck(store.likedAlbums.isEmpty, "Store must hide likedAlbums when catalog disabled")
        assertCheck(store.likedArtists.isEmpty, "Store must hide likedArtists when catalog disabled")
        assertCheck(store.dislikedArtists.isEmpty, "Store must hide dislikedArtists when catalog disabled")
        assertCheck(store.likedPlaylists.isEmpty, "Store must hide likedPlaylists when catalog disabled")
        assertCheck(store.playlistTracks(owner: uid, kind: "10").isEmpty, "Store must hide playlistTracks when catalog disabled")

        Settings.catalog = true
        store.load(uid: uid)
        assertCheck(store.likedTracks == ["9000000001"], "Persisted likedTracks must be preserved on re-enable")
        assertCheck(store.dislikedTracks == ["9000000002"], "Persisted dislikedTracks must be preserved")
        assertCheck(store.likedAlbums == ["900000001"], "Persisted likedAlbums must be preserved")
        assertCheck(store.likedArtists == ["90000001"], "Persisted likedArtists must be preserved")
        assertCheck(store.dislikedArtists == ["90000002"], "Persisted dislikedArtists must be preserved")
        assertCheck(store.likedPlaylists == ["9000001"], "Persisted likedPlaylists must be preserved")
        assertCheck(store.playlistTracks(owner: uid, kind: "10") == ["9000000001"], "Persisted playlistTracks must be preserved")
    }

    private static func testCatalogLibraryRoundtrip() throws {
        var lib = CatalogLibrary()
        lib.setTrackLiked("9000000001", true)
        lib.setTrackLiked("9000000002", true)
        assertCheck(lib.likedTracks == ["9000000002", "9000000001"], "Track likes should insert newest first")
        lib.setTrackDisliked("9000000002", true)
        assertCheck(lib.likedTracks == ["9000000001"], "Disliking a liked track must remove its like")
        assertCheck(lib.dislikedTracks == ["9000000002"], "Disliked track must be recorded")

        lib.setArtistLiked("90000001", true)
        lib.setArtistDisliked("90000001", true)
        assertCheck(lib.likedArtists.isEmpty && lib.dislikedArtists == ["90000001"], "Disliking artist must clear artist like")

        lib.setAlbumLiked("900000001", true)
        lib.setPlaylistLiked("9000001", true)

        let added = lib.addPlaylistTracks(["9000000001", "9000000002"], to: "user:1")
        assertCheck(added == 2, "Should report 2 newly added playlist tracks")
        assertCheck(lib.playlistTracks["user:1"] == ["9000000001", "9000000002"], "Playlist tracks order mismatch")

        lib.movePlaylistTrack("9000000002", in: "user:1", before: "9000000001")
        assertCheck(lib.playlistTracks["user:1"] == ["9000000002", "9000000001"], "Playlist reorder before target failed")

        let removed = lib.removePlaylistTrack("9000000001", from: "user:1")
        assertCheck(removed && lib.playlistTracks["user:1"] == ["9000000002"], "Playlist remove failed")

        lib.setPin("album:900000001", pinned: true)

        let encoded = try JSONEncoder().encode(lib)
        let decoded = try JSONDecoder().decode(CatalogLibrary.self, from: encoded)
        assertCheck(decoded == lib, "CatalogLibrary Codable roundtrip must preserve all fields")
    }

    private static func testTrackCodableBackwardCompatibility() throws {
        let legacyJSON = """
        {
          "id": "123",
          "title": "Track",
          "artists": "Artist",
          "artistList": [{"id": "10", "name": "Artist"}],
          "durationMs": 180000,
          "albumTitle": "Album",
          "explicit": false,
          "hasLyrics": false,
          "unavailable": false,
          "uncensored": false
        }
        """
        let legacyTrack = try JSONDecoder().decode(Track.self, from: Data(legacyJSON.utf8))
        assertCheck(legacyTrack.catalog == nil && !legacyTrack.isCatalog, "Legacy Track JSON must decode with isCatalog == false")

        let catalogJSON = """
        {
          "id": "9000000001",
          "title": "Камен",
          "artists": "Ёжик",
          "artistList": [{"id": "90000001", "name": "Ёжик"}],
          "durationMs": 186000,
          "albumTitle": "Первый альбом",
          "explicit": false,
          "hasLyrics": false,
          "unavailable": false,
          "uncensored": false,
          "catalog": true
        }
        """
        let catalogTrack = try JSONDecoder().decode(Track.self, from: Data(catalogJSON.utf8))
        assertCheck(catalogTrack.isCatalog && !catalogTrack.isPrivate, "Synthetic catalog track must have isCatalog == true and isPrivate == false")
    }

    private static func testExternalLyricsSkipsYandexForSyntheticTrack() async {
        let synthetic = Track(
            id: "9000000001",
            title: "Камен",
            version: nil,
            artists: "Ёжик",
            artistList: [ArtistRef(id: "90000001", name: "Ёжик")],
            durationMs: 186_000,
            cover: nil,
            albumId: "900000001",
            albumTitle: "Первый альбом",
            explicit: false,
            hasLyrics: false,
            unavailable: false,
            uncensored: false,
            batch: nil,
            loudness: nil,
            peak: nil,
            fade: nil,
            mixFade: nil,
            ugc: false,
            catalog: true
        )
        let opts = ExternalLyrics.Options(external: true, always: false, lrclib: true, netease: true, neteaseFirst: false, mirror: "")
        var yandexCalled = false
        var lrclibCalled = false
        let (result, complete) = await ExternalLyrics.find(
            synthetic,
            options: opts,
            yandex: { _ in
                yandexCalled = true
                return LyricsText(lines: [], authors: nil, source: LyricsText.yandex)
            },
            lrclib: { _ in
                lrclibCalled = true
                return LyricsText(lines: [LyricLine(id: 0, time: 1.0, text: "Строка")], authors: nil, source: "LRCLIB")
            },
            netease: { _ in nil }
        )
        assertCheck(!yandexCalled, "Yandex lyrics API must not be called for synthetic catalog track")
        assertCheck(lrclibCalled && complete && result.source == "LRCLIB", "External LRCLIB must run for synthetic catalog track")
    }
}
