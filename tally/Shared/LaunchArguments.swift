import Foundation
import SwiftData
import TallyKit

/// Launch arguments the XCUITest suite uses to put the app in a known state.
///
/// PLAN Gate 1 re-runs the UI suite at every later gate, so the tests must not
/// depend on whatever the simulator happened to have on disk: they ask for a
/// throwaway store and an explicit onboarding state instead.
enum LaunchArguments {

    /// Fresh in-memory store — today's counts start at zero, and nothing the
    /// test logs survives the run.
    static let inMemoryStore = "-tally-uitest-in-memory-store"

    /// Straight to the counter, whatever the persisted flag says.
    static let skipOnboarding = "-tally-uitest-skip-onboarding"

    /// Force the first-run flow (SPEC §9) even on a device that has seen it.
    static let resetOnboarding = "-tally-uitest-reset-onboarding"

    private static var arguments: Set<String> {
        Set(ProcessInfo.processInfo.arguments)
    }

    static var wantsInMemoryStore: Bool { arguments.contains(inMemoryStore) }
    static var wantsSkipOnboarding: Bool { arguments.contains(skipOnboarding) }
    static var wantsResetOnboarding: Bool { arguments.contains(resetOnboarding) }

    /// Which store the app opens. Everything but a UI test gets the shared App
    /// Group store the widget also reads (SPEC §1).
    static var storeConfiguration: StoreConfiguration {
        wantsInMemoryStore ? .inMemory : .default
    }
}

/// Where the "have we run the first-run flow" bit lives (SPEC §9).
enum OnboardingState {

    static let storageKey = "tally.onboarding.completed"

    /// Applies the UI-test overrides before any view reads `@AppStorage`.
    static func applyLaunchArgumentOverrides() {
        if LaunchArguments.wantsResetOnboarding {
            UserDefaults.standard.set(false, forKey: storageKey)
        } else if LaunchArguments.wantsSkipOnboarding {
            UserDefaults.standard.set(true, forKey: storageKey)
        }
    }
}

/// The container SwiftUI previews render against. Always in-memory: a preview
/// must never touch the real App Group store.
enum PreviewStore {

    static let container: ModelContainer = {
        do {
            return try TallyStore.makeInMemoryContainer()
        } catch {
            fatalError("Preview store unavailable: \(error)")
        }
    }()
}
