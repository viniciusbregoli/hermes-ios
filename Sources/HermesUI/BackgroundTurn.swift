#if os(iOS)
import UIKit

/// iOS suspends the app moments after it leaves the screen, which would cut the socket before a short turn
/// ends and its notification is posted. While a turn runs and the app is away, a background task keeps it
/// alive for the few seconds iOS grants (about 30). A longer turn needs push from the server, which Hermes
/// doesn't offer: its notification arrives when the app is next opened.
@MainActor
final class BackgroundTurn {
    static let shared = BackgroundTurn()
    private var task = UIBackgroundTaskIdentifier.invalid

    /// Call when the app leaves the foreground or comes back, and when a turn starts or ends.
    func update(away: Bool, running: Bool) {
        if away, running {
            guard task == .invalid else { return }
            task = UIApplication.shared.beginBackgroundTask(withName: "turn") { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        } else if task != .invalid {
            // The notification is handed to the system just before this runs; give it a moment to leave the process.
            Task {
                try? await Task.sleep(for: .seconds(2))
                end()
            }
        }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif
