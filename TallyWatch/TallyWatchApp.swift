import SwiftUI
import TallyKit

/// Wave 0 placeholder so the target is complete and links.
///
/// The Wave 1 `watch` agent owns this directory and fills in SPEC §7: the single
/// counter screen with +1 alcoholic / +1 NA and swipe-to-undo, accessory
/// complications, and WatchConnectivity mirroring.
@main
struct TallyWatchApp: App {

    init() {
        // SPEC §7: the watch keeps its own store using the identical schema, and
        // stamps its events so the phone can reconcile venues on next open.
        TallyRuntime.configure(eventSource: .watch, storeConfiguration: .local)
    }

    var body: some Scene {
        WindowGroup {
            TallyWatchRootView()
        }
    }
}

struct TallyWatchRootView: View {

    var body: some View {
        VStack(spacing: 6) {
            Text("Tally")
                .font(.headline)
            Text("Counter lands in Wave 1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    TallyWatchRootView()
}
