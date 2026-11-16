import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct PlaybackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let playing: Bool
        var progress: Progress?
    }

    struct Progress: Codable, Hashable {
        let elapsed: Double
        let duration: Double
        let rate: Double
        let updated: Date

        var interval: ClosedRange<Date>? {
            guard rate > 0, duration > elapsed else { return nil }
            let start = updated.addingTimeInterval(-elapsed / rate)
            return start...start.addingTimeInterval(duration / rate)
        }
    }
}
