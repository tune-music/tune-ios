import Foundation

enum YnisonProtocol {
    static let redirectHost = "ynison.music.yandex.ru"
    static let redirectPath = "/redirector.YnisonRedirectService/GetRedirectToYnison"
    static let hubPath = "/ynison_state.YnisonStateService/PutYnisonState"

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: String
        var speaker: Bool { kind.contains("SPEAKER") || kind.contains("STATION") }
    }

    struct Song: Equatable {
        let id: String
        let album: String?
        let title: String
        let cover: String?

        init(track: Track) {
            self.init(id: track.id, album: track.albumId, title: track.title,
                      cover: track.cover?.hasPrefix("tune-override:") == true ? nil : track.cover)
        }

        init(id: String, album: String?, title: String, cover: String?) {
            self.id = id
            self.album = album
            self.title = title
            self.cover = cover
        }
    }

    struct Playback: Equatable {
        var songs: [Song] = []
        var index: Int?
        var entityID = ""
        var entityType = "VARIOUS"
        var paused = true
        var position: Double = 0
        var duration: Double = 0
        var speed: Double = 1

        var current: Song? { index.flatMap { songs.indices.contains($0) ? songs[$0] : nil } }

        func predicted(after seconds: Double) -> Double {
            let value = position + (paused ? 0 : max(0, seconds) * speed)
            return duration > 0 ? min(value, duration) : value
        }

        func sameQueue(as other: Self) -> Bool {
            entityID == other.entityID && entityType == other.entityType && index == other.index
                && songs.elementsEqual(other.songs) { $0.id == $1.id && $0.album == $1.album }
        }
    }

    struct State: Equatable {
        var devices: [Device] = []
        var active: String?
        var playback = Playback()
        var statusBy: String?
        var queueBy: String?
        var statusVersion: String?
        var queueVersion: String?
    }

    static func socketURL(host: String, path: String) throws -> URL {
        let normalized = host.lowercased()
        guard normalized == "yandex.ru" || normalized.hasSuffix(".yandex.ru")
                || normalized.hasSuffix(".yandex.net"),
              normalized.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            throw ProtocolError("Ynison прислал неизвестный адрес")
        }
        var parts = URLComponents()
        parts.scheme = "wss"
        parts.host = normalized
        parts.path = path
        guard let url = parts.url, url.host == normalized else { throw ProtocolError("Неверный адрес Ynison") }
        return url
    }

    static func protocols(token: String, device: String, extra: [String: Any]) throws -> [String] {
        let info = try encode(["app_name": "Desktop", "app_version": "5.120.0", "type": 1])
        var fields = extra
        fields["Ynison-Device-Id"] = device
        fields["Ynison-Device-Info"] = info
        fields["authorization"] = "OAuth \(token)"
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let value = try encode(fields)
        guard let header = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ProtocolError("Не удалось подготовить подключение Ynison")
        }
        return ["Bearer", "v2", header]
    }

    static func encode(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func message(_ fields: [String: Any], intercept: Bool = false) throws -> String {
        var body = fields
        body["rid"] = UUID().uuidString.lowercased()
        body["player_action_timestamp_ms"] = timestamp()
        body["activity_interception_type"] = intercept ? "INTERCEPT_EAGER" : "DO_NOT_INTERCEPT_BY_DEFAULT"
        return try encode(body)
    }

    private static func timestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func version(_ id: String) -> [String: Any] {
        ["device_id": id, "version": Int64.random(in: 1...(Int64.max / 4)), "timestamp_ms": timestamp()]
    }

    static func device(_ id: String) -> [String: Any] {
        [
            "volume": 1.0,
            "volume_info": ["volume": 1.0, "version": NSNull()],
            "capabilities": ["can_be_player": true, "can_be_remote_controller": false, "volume_granularity": 20],
            "info": ["app_name": "Desktop", "app_version": "5.120.0", "title": "Tune на iPhone", "device_id": id, "type": "WEB_DESKTOP"],
            "is_shadow": false
        ]
    }

    static func status(_ playback: Playback, device: String) -> [String: Any] {
        ["duration_ms": Int64(playback.duration * 1_000), "paused": playback.paused,
         "playback_speed": playback.speed, "progress_ms": Int64(playback.position * 1_000), "version": version(device)]
    }

    static func player(_ playback: Playback, device: String) -> [String: Any] {
        let songs = playback.songs.map { song -> [String: Any] in
            ["album_id_optional": (song.album as Any?) ?? NSNull(), "from": "tune-ios",
             "playable_id": song.id, "playable_type": "TRACK", "title": song.title,
             "cover_url_optional": (song.cover as Any?) ?? NSNull(), "navigation_id_optional": NSNull(),
             "playback_action_id_optional": NSNull()]
        }
        let queue: [String: Any] = [
            "current_playable_index": playback.index ?? -1, "entity_id": playback.entityID,
            "entity_type": playback.entityType, "playable_list": songs, "options": ["repeat_mode": "NONE"],
            "shuffle_optional": NSNull(), "entity_context": "BASED_ON_ENTITY_BY_DEFAULT",
            "version": version(device), "from_optional": "tune-ios", "initial_entity_optional": NSNull(),
            "adding_options_optional": NSNull(), "queue": NSNull()
        ]
        return ["player_queue": queue, "status": status(playback, device: device), "player_queue_inject_optional": NSNull()]
    }

    static func state(_ value: JSON) -> State? {
        guard value["devices"].isArray || value["player_state"].isObject else { return nil }
        var result = State()
        var seen = Set<String>()
        result.devices = value["devices"].array.compactMap { device in
            let info = device["info"]
            guard device["is_shadow"].bool != true, device["capabilities"]["can_be_player"].bool != false,
                  let id = info["device_id"].idText, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return Device(id: id, name: info["title"].string ?? "Устройство", kind: info["type"].string ?? "")
        }
        let queue = value["player_state"]["player_queue"]
        let status = value["player_state"]["status"]
        let songs = queue["playable_list"].array.map { song in
            Song(id: song["playable_id"].idText ?? "", album: song["album_id_optional"].idText,
                 title: song["title"].string ?? "", cover: song["cover_url_optional"].string)
        }
        let index = queue["current_playable_index"].idText.flatMap(Int.init).flatMap { songs.indices.contains($0) ? $0 : nil }
        func seconds(_ field: String) -> Double {
            let value = status[field].idText.flatMap(Double.init) ?? 0
            return value.isFinite ? max(0, min(value / 1_000, 1_000_000_000)) : 0
        }
        let speed = status["playback_speed"].idText.flatMap(Double.init) ?? 1
        result.playback = Playback(songs: songs, index: index, entityID: queue["entity_id"].idText ?? "",
                                   entityType: queue["entity_type"].string ?? "VARIOUS", paused: status["paused"].bool ?? true,
                                   position: seconds("progress_ms"), duration: seconds("duration_ms"),
                                   speed: speed.isFinite ? min(max(speed, 0.1), 10) : 1)
        result.active = value["active_device_id_optional"].idText.flatMap { $0.isEmpty ? nil : $0 }
        result.statusBy = status["version"]["device_id"].idText
        result.queueBy = queue["version"]["device_id"].idText
        result.statusVersion = status["version"]["version"].idText
        result.queueVersion = queue["version"]["version"].idText
        return result
    }

    private struct ProtocolError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
