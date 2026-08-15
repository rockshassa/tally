import SwiftUI
import TallyKit
import WidgetKit

/// The widget extension's entry point (SPEC §6).
///
/// Two widgets ship: `TallyCounterWidget` for the home screen (small and medium,
/// with interactive log buttons) and `TallyGlanceWidget` for the lock screen.
@main
struct TallyWidgetBundle: WidgetBundle {

    init() {
        // Everything logged from this process is a widget event (SPEC §6), and
        // reconciliation on next app open keys off exactly that. This runs both
        // when the extension renders a timeline and when it executes a
        // `LogDrinkIntent` from a widget button, so no event can escape the
        // stamp.
        TallyRuntime.configure(eventSource: .widget)
    }

    var body: some Widget {
        TallyCounterWidget()
        TallyGlanceWidget()
    }
}
