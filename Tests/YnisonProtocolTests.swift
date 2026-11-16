import Foundation

@main
struct YnisonProtocolTests {
    static func main() throws {
        let wire: [String: Any] = [
            "active_device_id_optional": "station",
            "devices": [
                ["info": ["device_id": "station", "title": "Гостиная", "type": "SMART_SPEAKER"]],
                ["info": ["device_id": "shadow"], "is_shadow": true],
                ["info": ["device_id": "remote"], "capabilities": ["can_be_player": false]]
            ],
            "player_state": [
                "player_queue": [
                    "playable_list": [["playable_id": 123, "title": "Трек"], ["playable_id": "ugc-1"]],
                    "current_playable_index": "0", "version": ["device_id": "station", "version": 7]
                ],
                "status": ["progress_ms": "61000", "duration_ms": 120_000, "paused": false, "playback_speed": 1.25]
            ]
        ]
        guard let state = YnisonProtocol.state(JSON(wire)) else { fatalError("Failed to parse hub state") }
        precondition(state.devices.map(\.id) == ["station"] && state.devices[0].speaker)
        precondition(state.active == "station" && state.queueVersion == "7")
        precondition(state.playback.current?.id == "123")
        precondition(state.playback.predicted(after: 4) == 66)
        precondition(state.playback.predicted(after: 300) == 120)

        let payload = YnisonProtocol.player(state.playback, device: "iphone")
        let encoded = try YnisonProtocol.message(["update_player_state": ["player_state": payload]], intercept: true)
        let message = JSON.parse(Data(encoded.utf8))
        precondition(message["activity_interception_type"].string == "INTERCEPT_EAGER")
        let player = message["update_player_state"]["player_state"]
        precondition(player["player_queue"]["current_playable_index"].int == 0)
        precondition(player["player_queue"]["playable_list"][1]["playable_id"].string == "ugc-1")
        precondition(player["status"]["progress_ms"].int == 61_000)

        let protocols = try YnisonProtocol.protocols(token: "test token", device: "iphone", extra: [:])
        precondition(protocols.prefix(2).elementsEqual(["Bearer", "v2"]))
        let credentials = JSON.parse(Data((protocols[2].removingPercentEncoding ?? "").utf8))
        precondition(credentials["authorization"].string == "OAuth test token")
        precondition(credentials["Ynison-Device-Id"].string == "iphone")

        let host = try YnisonProtocol.socketURL(host: "node.music.yandex.ru", path: YnisonProtocol.hubPath)
        precondition(host.scheme == "wss" && host.host == "node.music.yandex.ru")
        for unsafe in ["music.yandex.ru.example.org", "evil.example@music.yandex.ru", "music.yandex.ru:80"] {
            precondition((try? YnisonProtocol.socketURL(host: unsafe, path: YnisonProtocol.hubPath)) == nil)
        }
        print("Ynison protocol checks passed")
    }
}
