import SwiftUI
import TallyKit

/// Retro-logging (SPEC §1): *"long-press either button to add a drink at a
/// custom time (no location attached, since we can't know where you were)."*
///
/// The no-location rule is enforced structurally — this sheet's only output is a
/// timestamp, and the caller logs with coordinates left nil.
struct RetroLogSheet: View {

    let type: DrinkType

    /// Called with the chosen time. The caller writes the event.
    let onLog: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var timestamp: Date = Date()

    /// Nothing in the future: you cannot have had a drink that has not happened.
    private var range: ClosedRange<Date> {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return weekAgo...now
    }

    private var tint: TallyDrinkTint {
        type == .alcoholic ? .alcoholic : .nonAlcoholic
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TallyColor.pageGradient.ignoresSafeArea()

                VStack(spacing: 20) {
                    VStack(spacing: 6) {
                        Text(type == .alcoholic ? "Add a drink" : "Add a non-alcoholic drink")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(TallyColor.ink)

                        Text("Logged at the time you pick. No location is attached.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(TallyColor.inkSecondary)
                    }

                    DatePicker(
                        "When",
                        selection: $timestamp,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .tint(TallyColor.brightTint(for: tint))
                    .accessibilityIdentifier(A11y.RetroLog.datePicker)

                    Spacer(minLength: 0)

                    Button("Log it") {
                        onLog(timestamp)
                        dismiss()
                    }
                    .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.tint(for: tint)))
                    .accessibilityIdentifier(A11y.RetroLog.confirmButton)
                }
                .padding(TallyMetrics.screenPadding)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11y.RetroLog.cancelButton)
                }
            }
        }
        .accessibilityIdentifier(A11y.RetroLog.sheet)
        .presentationDetents([.large])
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            RetroLogSheet(type: .alcoholic) { _ in }
        }
        .preferredColorScheme(.dark)
}
