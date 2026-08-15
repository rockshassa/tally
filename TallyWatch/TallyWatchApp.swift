import SwiftUI
import TallyKit

/// The watchOS app (SPEC §7): logging from the wrist, and nothing else.
@main
struct TallyWatchApp: App {

    init() {
        // SPEC §7: the watch keeps its own store using the identical schema, and
        // stamps its events so the phone can reconcile venues on next open.
        // App Group (not .local) so the complication extension — a separate
        // process — reads the same store. App Groups do not cross devices.
        TallyRuntime.configure(eventSource: .watch, storeConfiguration: .default)

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
