//
//  WatchCounterView.swift
//  The entire watch app: one screen (SPEC §7).
//
//  Today's two counts, doubling as the two log buttons, plus swipe-to-undo on
//  either. Deliberately nothing else — no trends, no settings, no navigation.
//  Layout follows design/ux-mockups.html §7.
//

import Combine
import SwiftUI
import TallyKit

struct WatchCounterView: View {

    @State private var model = WatchTallyModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                countRow(.alcoholic, count: model.counts.alcoholic)
                countRow(.nonAlcoholic, count: model.counts.nonAlcoholic)
                footerRow
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(WatchTheme.background)
            .navigationTitle("Tally")
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            // Catches the day rolling over while the app sat in the background,
            // and anything the phone merged in meanwhile.
            if phase == .active { model.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tallySyncDidApplyRemoteChanges)) { _ in
            model.refresh()
        }
    }

    // MARK: - Count rows

    /// One row is both the readout and the button — the same surface you glance
    /// at is the one you tap, which is what makes it a one-tap counter.
    private func countRow(_ type: DrinkType, count: Int) -> some View {
        Button {
            model.log(type)
        } label: {
            HStack(spacing: 10) {
                Text("+")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(WatchTheme.tint(for: type))

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(count)")
                        .font(.system(size: 21, weight: .heavy))
                        // Tabular figures so the row does not twitch when the
                        // count crosses 9 → 10.
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(WatchTheme.ink)

                    Text(WatchTheme.caption(for: type).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(WatchTheme.inkSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: count)
        .listRowInsets(EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2))
        .listRowBackground(rowBackground(for: type))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.undo(type)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(type.displayName)")
        .accessibilityHint("Double tap to add one. Swipe left to undo the most recent.")
    }

    private func rowBackground(for type: DrinkType) -> some View {
        let tint = WatchTheme.tint(for: type)
        let shape = RoundedRectangle(cornerRadius: WatchTheme.rowCornerRadius, style: .continuous)
        return shape
            .fill(tint.opacity(WatchTheme.rowFillOpacity(for: type)))
            .overlay(
                shape.strokeBorder(
                    tint.opacity(WatchTheme.rowStrokeOpacity(for: type)),
                    lineWidth: 1
                )
            )
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerRow: some View {
        Text(model.isStoreUnavailable ? "Store unavailable" : "Swipe a count to undo")
            .font(.system(size: 10))
            .foregroundStyle(WatchTheme.inkTertiary)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
            .accessibilityHidden(!model.isStoreUnavailable)
    }
}

#Preview {
    WatchCounterView()
}
