//
//  TallySyncService.swift
//  The WatchConnectivity link. Same code runs on both ends.
//
//  ⚠️ MIRRORED SOURCE — this file is byte-identical to its twin:
//
//        tally/Services/Connectivity/TallySyncService.swift
//        TallyWatch/Connectivity/TallySyncService.swift
//
//  Mirroring is symmetric by nature — each side queues its own changes and
//  upserts whatever the other sends — so one implementation serves both. The
//  copies exist only because the two targets share no module (TallyKit is
//  frozen for Wave 1). Keep them identical, or promote this file into TallyKit
//  at the Gate 1 integration and delete both copies.
//
//  SPEC §7:
//    • `transferUserInfo` — queued, survives the phone being unreachable at the bar
//    • merges dedupe by event UUID, so double delivery is harmless and idempotent
//    • the watch keeps its own store; this is a mirror, not a shared database
//

import Foundation
import SwiftData
import TallyKit
import WatchConnectivity

#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Notifications

public extension Notification.Name {

    /// Posted on the main actor after inbound events or tombstones have been
    /// merged into the local store. UI observes this to refresh its counts.
    nonisolated static let tallySyncDidApplyRemoteChanges = Notification.Name("TallySyncDidApplyRemoteChanges")
}

// MARK: - Tombstone ledger

/// A short memory of undone events, so a peer cannot resurrect them.
///
/// Undo deletes the event outright (SPEC §1), which leaves no trace to sync.
/// Without this ledger the next catch-up batch from the other device — which
/// still holds its copy — would put the drink straight back. Entries expire
/// after `retentionDays`, well past any plausible offline gap.
public nonisolated final class TallyTombstoneLedger: @unchecked Sendable {

    public static let retentionDays = 14

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, storageKey: String = "tally.sync.tombstones.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    private func loadLocked() -> [DrinkEventTombstone] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([DrinkEventTombstone].self, from: data)
        else { return [] }
        return stored
    }

    private func saveLocked(_ tombstones: [DrinkEventTombstone]) {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let pruned = tombstones.filter { $0.deletedAt >= cutoff }
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        defaults.set(data, forKey: storageKey)
    }

    public func record(_ tombstones: [DrinkEventTombstone]) {
        guard !tombstones.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var merged = loadLocked()
        let known = Set(merged.map(\.id))
        merged.append(contentsOf: tombstones.filter { !known.contains($0.id) })
        saveLocked(merged)
    }

    public func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().contains { $0.id == id }
    }

    /// Tombstones young enough to be worth re-announcing in a catch-up batch.
    public func recent(since date: Date) -> [DrinkEventTombstone] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { $0.deletedAt >= date }
    }
}

// MARK: - Service

/// Wraps `WCSession` for both ends of the link.
///
/// Deliberately `nonisolated`: `WCSessionDelegate` callbacks arrive on a
/// background queue, so the object itself must not be actor-bound. Everything
/// that touches SwiftData hops to the main actor explicitly.
public nonisolated final class TallySyncService: NSObject, WCSessionDelegate, @unchecked Sendable {

    public static let shared = TallySyncService()

    /// How far back a catch-up batch reaches (SPEC §7: recent history, both ways).
    public static let catchUpWindowDays = 7

    /// Floor between catch-up transfers, so a flapping connection cannot turn
    /// into a transfer storm.
    public static let minimumCatchUpInterval: TimeInterval = 60

    public let ledger: TallyTombstoneLedger

    private let lock = NSLock()
    private var hasActivated = false
    private var lastCatchUpSentAt: Date?

    public init(ledger: TallyTombstoneLedger = TallyTombstoneLedger()) {
        self.ledger = ledger
        super.init()
    }

    // MARK: Session access

    private var session: WCSession? {
        WCSession.isSupported() ? WCSession.default : nil
    }

    /// Whether a transfer can be handed to the session right now.
    ///
    /// Not the same as *reachable*: `transferUserInfo` is explicitly for the
    /// unreachable case — it queues. This only rules out the cases where there
    /// is no counterpart app at all to queue for.
    private func canTransfer(_ session: WCSession) -> Bool {
        guard session.activationState == .activated else { return false }
        #if os(iOS)
        return session.isPaired && session.isWatchAppInstalled
        #elseif os(watchOS)
        return session.isCompanionAppInstalled
        #else
        return true
        #endif
    }

    // MARK: - Activation

    /// Call once per process, as early as possible. Idempotent.
    public func activate() {
        lock.lock()
        if hasActivated {
            lock.unlock()
            return
        }
        hasActivated = true
        lock.unlock()

        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound

    /// Mirrors a locally logged drink. Queued — it survives the counterpart
    /// being out of range (SPEC §7).
    public func mirrorLog(_ snapshot: DrinkEventSnapshot) {
        transfer(.log(snapshot))
    }

    /// Mirrors a local undo as an explicit tombstone, and remembers it so an
    /// inbound catch-up cannot bring the event back.
    public func mirrorUndo(eventID: UUID, deletedAt: Date = Date()) {
        let tombstone = DrinkEventTombstone(id: eventID, deletedAt: deletedAt)
        ledger.record([tombstone])
        transfer(.undo(tombstone))
    }

    /// Sends everything from the last `catchUpWindowDays`, so a device that was
    /// off, unpaired, or simply never launched converges on reconnect.
    public func sendCatchUp(kind: TallySyncEnvelope.Kind = .catchUp, force: Bool = false) {
        guard force || !isCatchUpThrottled() else { return }

        Task { @MainActor in
            guard let envelope = self.makeCatchUpEnvelope(kind: kind) else { return }
            self.markCatchUpSent()
            self.transfer(envelope, allowEmpty: true)
        }
    }

    // Locking lives in these two synchronous helpers rather than inline: taking
    // an `NSLock` directly inside an async context is a Swift 6 error, since the
    // task could resume on a different thread than the one that locked.

    private func isCatchUpThrottled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastCatchUpSentAt else { return false }
        return Date().timeIntervalSince(last) < Self.minimumCatchUpInterval
    }

    private func markCatchUpSent() {
        lock.lock()
        defer { lock.unlock() }
        lastCatchUpSentAt = Date()
    }

    @MainActor
    private func makeCatchUpEnvelope(kind: TallySyncEnvelope.Kind) -> TallySyncEnvelope? {
        guard let container = try? TallyRuntime.container() else { return nil }
        // The container's own main context, not a fresh one: the UI reads from
        // this same context, so a merge lands where the counts are read and
        // there is no window in which the two disagree.
        let context = container.mainContext
        let since = Date().addingTimeInterval(-Double(Self.catchUpWindowDays) * 86_400)
        let events = (try? EventStore.events(from: since, to: .distantFuture, in: context))?.map(\.snapshot) ?? []
        return TallySyncEnvelope(
            kind: kind,
            events: events,
            tombstones: ledger.recent(since: since)
        )
    }

    private func transfer(_ envelope: TallySyncEnvelope, allowEmpty: Bool = false) {
        guard allowEmpty || !envelope.isEmpty else { return }
        guard let session, canTransfer(session) else { return }
        guard let userInfo = try? envelope.makeUserInfo() else { return }
        session.transferUserInfo(userInfo)
    }

    // MARK: - Inbound

    /// Merges an inbound envelope into the local store.
    ///
    /// Idempotent by construction: events go through `EventStore.upsert`, which
    /// dedupes on the app-level UUID, and deletes are matched by the same UUID.
    /// Replaying the identical envelope changes nothing (SPEC §7).
    @MainActor
    public func apply(_ envelope: TallySyncEnvelope) {
        guard let container = try? TallyRuntime.container() else { return }
        let context = container.mainContext

        // Tombstones first, and recorded before the upsert runs: a single batch
        // can carry both an event and its own tombstone, and the outcome must
        // not depend on which array happened to be processed first.
        ledger.record(envelope.tombstones)
        var didChange = false
        for tombstone in envelope.tombstones {
            if let event = try? EventStore.event(id: tombstone.id, in: context) {
                context.delete(event)
                didChange = true
            }
        }
        if didChange { try? context.save() }

        let survivors = envelope.events.filter { !ledger.contains($0.id) }
        if !survivors.isEmpty {
            let outcomes = (try? EventStore.upsert(survivors, in: context)) ?? [:]
            didChange = didChange || outcomes.values.contains { $0 != .unchanged }
        }

        if didChange {
            NotificationCenter.default.post(name: .tallySyncDidApplyRemoteChanges, object: nil)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }

        // Answer a catch-up with our own, so one side waking up is enough to
        // exchange both directions. A reply is never answered in turn.
        if envelope.kind == .catchUp {
            sendCatchUp(kind: .catchUpReply, force: true)
        }
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil else { return }
        sendCatchUp(force: true)
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let envelope = TallySyncEnvelope.decode(from: userInfo) else { return }
        Task { @MainActor in
            self.apply(envelope)
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        sendCatchUp()
    }

    #if os(iOS)
    /// The watch app appearing (or a new watch being paired) is the moment the
    /// counterpart store is empty and most needs the backfill.
    public func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        sendCatchUp()
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required on iOS: reactivate so the link follows the user to a new watch.
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
