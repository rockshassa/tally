//
//  WatchTallyModel.swift
//  The whole state of the watch app (SPEC §7).
//
//  Today's two counts, a log path, an undo path. No trends, no settings —
//  the wrist is the fastest way to record a drink and nothing else.
//
//  Every write goes to the **watch's own store** (SPEC §7: identical schema,
//  separate database) and is mirrored to the phone over WatchConnectivity.
//

import Foundation
import Observation
import SwiftData
import TallyKit
import WatchKit

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
@Observable
public final class WatchTallyModel {

    // MARK: State

    public private(set) var counts: TodayCounts = .zero

    /// Set when the local store could not be opened. The buttons stay visible
    /// but inert — better an honest empty screen than a crash at the bar.
    public private(set) var isStoreUnavailable = false

    // MARK: Collaborators

    private let sync: TallySyncService
    private let location: WatchLocationProvider
    private let permissions: LivePermissionsService
    private var context: ModelContext?

    // Defaults resolve inside the body rather than in the parameter list:
    // default arguments are evaluated in a nonisolated context, and both of
    // these are main-actor types.
    public init(
        sync: TallySyncService = .shared,
        location: WatchLocationProvider? = nil,
        permissions: LivePermissionsService? = nil
    ) {
        self.sync = sync
        self.location = location ?? .shared
        self.permissions = permissions ?? LivePermissionsService()
    }

    // MARK: - Lifecycle

    public func start() {
        if context == nil {
            if let container = try? TallyRuntime.container() {
                // The container's main context — the same one `TallySyncService`
                // merges inbound events into, so an arriving phone event is
                // visible here the moment it lands.
                context = container.mainContext
                isStoreUnavailable = false
            } else {
                isStoreUnavailable = true
            }
        }
        refresh()
    }

    /// Recomputes today's counts from the log. Aggregates are always derived,
    /// never stored (SPEC §1), so this is the only way counts ever change.
    public func refresh() {
        guard let context else { return }
        counts = (try? TodayCounts.load(in: context)) ?? .zero
    }

    // MARK: - Logging

    /// One tap → one event. Returns immediately; the location fix, if any, is
    /// attached afterwards (SPEC §6, §7: the count never waits on GPS).
    public func log(_ type: DrinkType) {
        guard let context else {
            WKInterfaceDevice.current().play(.failure)
            return
        }

        // A fix from the last minute is free — the second drink of a round
        // should not re-run GPS.
        let cached = location.freshCachedFix
        let id = UUID()

        do {
            let event = try EventStore.logDrink(
                type: type,
                timestamp: Date(),
                source: .watch,
                latitude: cached?.coordinate.latitude,
                longitude: cached?.coordinate.longitude,
                horizontalAccuracy: cached?.horizontalAccuracy,
                id: id,
                in: context
            )
            refresh()
            WKInterfaceDevice.current().play(.click)
            sync.mirrorLog(event.snapshot)
            reloadComplications()
        } catch {
            WKInterfaceDevice.current().play(.failure)
            return
        }

        if cached == nil {
            Task { await attachFix(to: id) }
        }
    }

    /// SPEC §1/§7: removes the most recent event of this type today and mirrors
    /// the delete as an explicit tombstone. No-ops at zero.
    public func undo(_ type: DrinkType) {
        guard let context,
              let today = try? EventStore.events(onDayContaining: Date(), in: context),
              let victim = today.last(where: { $0.type == type })
        else {
            WKInterfaceDevice.current().play(.failure)
            return
        }

        // Read the id before the delete — afterwards there is nothing to read.
        let victimID = victim.id
        guard (try? EventStore.undoMostRecent(type: type, in: context)) == true else {
            WKInterfaceDevice.current().play(.failure)
            return
        }

        refresh()
        WKInterfaceDevice.current().play(.click)
        sync.mirrorUndo(eventID: victimID)
        reloadComplications()
    }

    // MARK: - Location

    /// Best effort, strictly after the fact.
    ///
    /// The event is already saved and already mirrored. If a fix lands within
    /// the timeout, the *same UUID* is upserted with coordinates and re-sent —
    /// the merge is idempotent by construction (SPEC §7), so the phone treats
    /// the second delivery as an update rather than a duplicate drink.
    ///
    /// The watch never infers a venue. That stays on the phone, which offers
    /// reconciliation for untagged watch events on next open (SPEC §6, §7).
    private func attachFix(to id: UUID) async {
        var authorization = location.authorization
        if authorization.canPrompt {
            // Just-in-time (SPEC §9): the prompt appears *after* the drink is
            // already counted, so declining costs the user nothing.
            authorization = await permissions.requestLocationWhenInUse()
        }
        guard authorization.allowsOneShotFix else { return }
        guard let fix = await location.oneShotFix() else { return }

        guard let context,
              let event = try? EventStore.event(id: id, in: context)
        else { return }  // undone while the fix was in flight

        let patched = DrinkEventSnapshot(
            id: id,
            type: event.type,
            timestamp: event.timestamp,
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            horizontalAccuracy: fix.horizontalAccuracy,
            source: .watch,
            venueID: event.venue?.id
        )
        guard (try? EventStore.upsert(patched, in: context)) != nil else { return }
        sync.mirrorLog(patched)
    }

    // MARK: - Complications

    private func reloadComplications() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
