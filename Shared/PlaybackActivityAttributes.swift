import ActivityKit

@available(iOS 16.2, *)
struct PlaybackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let playing: Bool
    }
}
