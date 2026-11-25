import ActivityKit
import UIKit

@available(iOS 16.2, *)
@MainActor
final class PlaybackActivity {
    static let shared = PlaybackActivity()
    static let preferenceKey = "playbackLiveActivity"

    private typealias LiveActivity = Activity<PlaybackActivityAttributes>
    private typealias State = PlaybackActivityAttributes.ContentState

    private var desired: State?
    private var pending: Task<Void, Never>?
    private var changed = false

    private init() {}

    func refresh(track: Track?, playing: Bool, elapsed: Double, duration: Double, rate: Double) {
        desired = nil
        changed = true
        guard pending == nil else { return }
        pending = Task {
            while changed {
                changed = false
                await reconcile()
            }
            pending = nil
        }
    }

    private func reconcile() async {
        let existing = LiveActivity.activities
        guard let desired, ActivityAuthorizationInfo().areActivitiesEnabled else {
            for activity in existing { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: desired, staleDate: nil)
        if let activity = existing.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            if activity.content.state != desired { await activity.update(content) }
        } else if desired.playing, UIApplication.shared.applicationState == .active {
            do {
                _ = try LiveActivity.request(attributes: PlaybackActivityAttributes(), content: content, pushType: nil)
            } catch {
                Log.shared.add("Live Activity: \(error.localizedDescription)")
            }
        }
    }
}
