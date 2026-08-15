import SwiftData
import SwiftUI

/// The three-tab shell (SPEC §9): Tally, Trends, You.
///
/// Trends and You are placeholders until Wave 2 lands; History is not a tab —
/// it lives behind the today count on the Tally tab, which is why the Tally tab
/// owns the navigation stack.
struct RootTabView: View {

    @State private var selection: RootTab = .tally

    var body: some View {
        TabView(selection: $selection) {
            Tab("Tally", systemImage: "plus.circle.fill", value: RootTab.tally) {
                NavigationStack {
                    TallyScreen()
                }
                .accessibilityIdentifier(A11y.Tab.tally)
            }

            Tab("Trends", systemImage: "chart.bar.xaxis", value: RootTab.trends) {
                NavigationStack {
                    TrendsPlaceholderView()
                        .navigationTitle("Trends")
                }
                .accessibilityIdentifier(A11y.Tab.trends)
            }

            Tab("You", systemImage: "person.crop.circle", value: RootTab.you) {
                NavigationStack {
                    YouPlaceholderView()
                        .navigationTitle("You")
                }
                .accessibilityIdentifier(A11y.Tab.you)
            }
        }
        .tint(TallyColor.amberBright)
    }
}

enum RootTab: Hashable {
    case tally
    case trends
    case you
}

#Preview {
    RootTabView()
        .preferredColorScheme(.dark)
        .modelContainer(PreviewStore.container)
}
