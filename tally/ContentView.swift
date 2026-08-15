import SwiftData
import SwiftUI
import TallyKit

/// The root view: first run shows onboarding, every run after it shows the tab
/// shell (SPEC §9).
///
/// The flag is a single `@AppStorage` bool rather than anything derived from the
/// store, because "have you seen the three screens" is a property of the install,
/// not of the data — erasing all data (SPEC §9) must not replay onboarding.
struct ContentView: View {

    let permissions: any PermissionsService

    @AppStorage(OnboardingState.storageKey) private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                RootTabView(permissions: permissions)
            } else {
                OnboardingFlow(permissions: permissions) {
                    hasCompletedOnboarding = true
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: hasCompletedOnboarding)
    }
}

#Preview("Root") {
    ContentView(permissions: MockPermissionsService())
        .preferredColorScheme(.dark)
        .modelContainer(PreviewStore.container)
}

#Preview("First run") {
    OnboardingFlow(permissions: MockPermissionsService()) {}
        .preferredColorScheme(.dark)
        .modelContainer(PreviewStore.container)
}
