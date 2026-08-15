import SwiftUI
import TallyKit

/// The watchOS app (SPEC §7): logging from the wrist, and nothing else.
@main
struct TallyWatchApp: App {

    init() {
        // SPEC §7: the watch keeps its own store using the identical schema, and
        // stamps its events so the phone can reconcile venues on next open.
        TallyRuntime.configure(eventSource: .watch, storeConfiguration: .local)

        // Start the mirror before any UI exists, so a batch queued while the app
        // was closed is already on its way by the time the counter appears.
        TallySyncService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchCounterView()
        }
    }
}
