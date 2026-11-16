import Network
import SwiftUI

@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()

    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    var offline: Bool { Settings.offlineMode || !online }

    private init() {
        guard !Demo.on else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.online != online else { return }
                self.online = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "tune.connectivity"))
    }
}
