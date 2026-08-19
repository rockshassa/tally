//
//  PhoneConnectivityService.swift
//  The phone end of the watch mirror (SPEC §7).
//
//  This is the integration surface. `TallySyncService` does the actual
//  WatchConnectivity work — identically on both devices — and this wraps it in
//  the vocabulary the iOS app speaks: activate once at launch, tell it when the
//  app logs or undoes something, and let it fold whatever the watch sends into
//  the phone's store.
//
//  Nothing here reaches into another agent's files. The app can wire itself in
//  two ways, whichever is less intrusive:
//
//    1. Explicit call:      PhoneConnectivityService.shared.mirrorLog(snapshot)
//    2. Fire-and-forget:    PhoneConnectivityService.postDidLogEvent(snapshot)
//       (any code that can reach `NotificationCenter` can announce a change
//        without holding a reference to this service)
//

import Foundation
import SwiftData
import TallyKit
import UIKit

@MainActor
public final class PhoneConnectivityService {

    public static let shared = PhoneConnectivityService()

    // MARK: - Notification contract

    // `nonisolated` so a poster on any thread can name them without hopping.

    /// Post after the app writes a `DrinkEvent`, with the event's snapshot under
    /// `eventSnapshotKey`. The service mirrors it to the watch.
    public nonisolated static let didLogEventNotification = Notification.Name("TallyPhoneDidLogEvent")

    /// Post after the app deletes a `DrinkEvent`, with the deleted event's UUID
    /// under `eventIDKey`. Capture the id *before* deleting — undo removes the
    /// record outright (SPEC §1), so afterwards there is nothing left to read.
    public nonisolated static let didUndoEventNotification = Notification.Name("TallyPhoneDidUndoEvent")

    /// `userInfo` key carrying a `DrinkEventSnapshot`.
    public nonisolated static let eventSnapshotKey = "event"

    /// `userInfo` key carrying a `UUID`.
    public nonisolated static let eventIDKey = "eventID"

    /// Re-exported so a caller only needs to know about this one type: posted on
    /// the main actor once inbound watch changes have landed in the phone store.
    public nonisolated static let didApplyRemoteChangesNotification = Notification.Name.tallySyncDidApplyRemoteChanges

    // MARK: - State

    private let sync: TallySyncService
    private var observers: [any NSObjectProtocol] = []
    private var isActive = false

    public init(sync: TallySyncService = .shared) {
        self.sync = sync
    }

    // MARK: - Lifecycle

    /// Starts the link and the notification bridge. Call once at app launch —
    /// after `TallyRuntime.configure`, since inbound events need the store.
    /// Idempotent.
    public func activate() {
        guard !isActive else { return }
        isActive = true

        observers.append(
            NotificationCenter.default.addObserver(
                forName: Self.didLogEventNotification,
                object: nil,
                queue: .main
            ) { notification in
                let snapshot = notification.userInfo?[Self.eventSnapshotKey] as? DrinkEventSnapshot
                Task { @MainActor in
                    guard let snapshot else { return }
                    PhoneConnectivityService.shared.mirrorLog(snapshot)
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: Self.didUndoEventNotification,
                object: nil,
                queue: .main
            ) { notification in
                let eventID = notification.userInfo?[Self.eventIDKey] as? UUID
                Task { @MainActor in
                    guard let eventID else { return }
                    PhoneConnectivityService.shared.mirrorUndo(eventID: eventID)
                }
            }
        )

        sync.activate()

        // Widget-extension undos park tombstones in the App Group — the widget
        // process has no WCSession. Drain on activation and every foreground so
        // the watch hears about them before its next catch-up can resurrect.
        drainPendingTombstones()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    PhoneConnectivityService.shared.drainPendingTombstones()
                }
            }
        )
    }

    /// Mirrors any tombstones a widget-process undo left behind (SPEC §7 —
    /// merges dedupe by UUID, so re-draining is harmless).
    public func drainPendingTombstones() {
        for tombstone in PendingTombstoneQueue.drain() {
            mirrorUndo(eventID: tombstone.id, deletedAt: tombstone.deletedAt)
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Explicit send API

    /// Queues a phone-originated event for the watch.
    public func mirrorLog(_ snapshot: DrinkEventSnapshot) {
        sync.mirrorLog(snapshot)
    }

    /// Queues an undo. Represented on the wire as a `DrinkEventTombstone`; the
    /// watch deletes the matching event by UUID if it has one.
    public func mirrorUndo(eventID: UUID, deletedAt: Date = Date()) {
        sync.mirrorUndo(eventID: eventID, deletedAt: deletedAt)
    }

    /// Pushes the recent-history batch immediately instead of waiting for the
    /// next activation or reachability change.
    public func sendCatchUp() {
        sync.sendCatchUp(force: true)
    }

    // MARK: - Posting helpers

    public static func postDidLogEvent(_ snapshot: DrinkEventSnapshot) {
        NotificationCenter.default.post(
            name: didLogEventNotification,
            object: nil,
            userInfo: [eventSnapshotKey: snapshot]
        )
    }

    public static func postDidUndoEvent(eventID: UUID) {
        NotificationCenter.default.post(
            name: didUndoEventNotification,
            object: nil,
            userInfo: [eventIDKey: eventID]
        )
    }

    // MARK: - Convenience write paths

    // Optional sugar: log/undo *and* mirror in one call, so the mirroring step
    // cannot be forgotten and the undo path cannot lose the id by reading it
    // after the delete. Callers that prefer `EventStore` directly just post the
    // notifications above instead.

    @discardableResult
    public func logDrink(
        type: DrinkType,
        timestamp: Date = Date(),
        source: EventSource = .app,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        venue: Venue? = nil,
        in context: ModelContext
    ) throws -> DrinkEventSnapshot {
        let event = try EventStore.logDrink(
            type: type,
            timestamp: timestamp,
            source: source,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            venue: venue,
            in: context
        )
        let snapshot = event.snapshot
        mirrorLog(snapshot)
        return snapshot
    }

    /// Undo with mirroring. Returns the UUID that was removed, or `nil` when
    /// there was nothing to remove (SPEC §1: undo no-ops at zero).
    @discardableResult
    public func undoMostRecent(
        type: DrinkType,
        onDayContaining date: Date = Date(),
        calendar: Calendar = .current,
        in context: ModelContext
    ) throws -> UUID? {
        let today = try EventStore.events(onDayContaining: date, calendar: calendar, in: context)
        guard let victim = today.last(where: { $0.type == type }) else { return nil }
        let victimID = victim.id
        guard try EventStore.undoMostRecent(
            type: type,
            onDayContaining: date,
            calendar: calendar,
            in: context
        ) else { return nil }
        mirrorUndo(eventID: victimID)
        return victimID
    }
}
