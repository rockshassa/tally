//
//  TallySyncMessages.swift
//  The WatchConnectivity wire format shared by the phone and the watch.
//
//  ⚠️ MIRRORED SOURCE — this file is byte-identical to its twin:
//
//        tally/Services/Connectivity/TallySyncMessages.swift
//        TallyWatch/Connectivity/TallySyncMessages.swift
//
//  The two live in different targets (iOS app / watchOS app) and TallyKit was
//  frozen for Wave 1, so there is nowhere shared to put them yet. Keep both
//  copies identical — `diff` them — or, better, promote this file into TallyKit
//  at the Gate 1 integration and delete both copies.
//
//  SPEC §7: events mirror between watch and phone over WatchConnectivity, and
//  merges dedupe by event UUID so double delivery is harmless.
//

import Foundation
import TallyKit

// MARK: - Tombstone

/// An explicit "this event was undone" message (SPEC §1 undo deletes the event).
///
/// Deletes cannot ride along as an absence — a peer that never saw the delete
/// would happily re-send its copy on the next catch-up and resurrect it. So an
/// undo travels as its own small record, and each side keeps a short ledger of
/// the tombstones it knows about (`TallyTombstoneLedger`) to reject resurrections.
/// `nonisolated` throughout this file: the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and wire types are decoded on
/// the WatchConnectivity delegate queue, off the main actor.
public nonisolated struct DrinkEventTombstone: Codable, Hashable, Sendable, Identifiable {

    /// UUID of the deleted `DrinkEvent` — the same app-level identity the
    /// upsert path dedupes on.
    public let id: UUID

    public let deletedAt: Date

    public init(id: UUID, deletedAt: Date = Date()) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

// MARK: - Envelope

/// The single message type that crosses the WatchConnectivity link.
///
/// One shape covers every exchange, so there is exactly one decode path:
///
/// - a log      → `kind: .incremental`, one entry in `events`
/// - an undo    → `kind: .incremental`, one entry in `tombstones`
/// - a catch-up → `kind: .catchUp` / `.catchUpReply`, the last N days of both
public nonisolated struct TallySyncEnvelope: Codable, Hashable, Sendable {

    public enum Kind: String, Codable, Hashable, Sendable {

        /// A single local change, sent the moment it happens.
        case incremental

        /// A "here is everything recent I have" batch, sent on activation and on
        /// regaining reachability. Invites a reply.
        case catchUp

        /// The answer to a `.catchUp`. Never answered in turn — that is what
        /// stops the two sides from volleying forever.
        case catchUpReply
    }

    /// Bump only for a breaking change; `decode` rejects versions it cannot read
    /// rather than mis-parsing them.
    public static let currentVersion = 1

    /// Sole key in the `transferUserInfo` dictionary. The payload is JSON `Data`
    /// so the wire format is owned by `Codable`, not by plist coercion rules.
    public static let userInfoKey = "tally.sync.envelope.v1"

    public var version: Int
    public var kind: Kind
    public var sentAt: Date
    public var events: [DrinkEventSnapshot]
    public var tombstones: [DrinkEventTombstone]

    public init(
        version: Int = TallySyncEnvelope.currentVersion,
        kind: Kind,
        sentAt: Date = Date(),
        events: [DrinkEventSnapshot] = [],
        tombstones: [DrinkEventTombstone] = []
    ) {
        self.version = version
        self.kind = kind
        self.sentAt = sentAt
        self.events = events
        self.tombstones = tombstones
    }

    /// Nothing to say — used to skip empty transfers.
    public var isEmpty: Bool { events.isEmpty && tombstones.isEmpty }

    // MARK: Convenience constructors

    public static func log(_ event: DrinkEventSnapshot) -> TallySyncEnvelope {
        TallySyncEnvelope(kind: .incremental, events: [event])
    }

    public static func undo(_ tombstone: DrinkEventTombstone) -> TallySyncEnvelope {
        TallySyncEnvelope(kind: .incremental, tombstones: [tombstone])
    }

    // MARK: Coding

    // Dates use `JSONEncoder`'s default strategy on purpose: it round-trips a
    // `Date` exactly, so a re-delivered event compares equal to the stored one
    // and `EventStore.upsert` reports `.unchanged` instead of churning a write.
    private static func makeEncoder() -> JSONEncoder { JSONEncoder() }
    private static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    public func encoded() throws -> Data {
        try TallySyncEnvelope.makeEncoder().encode(self)
    }

    /// The `transferUserInfo` payload for this envelope.
    public func makeUserInfo() throws -> [String: Any] {
        [TallySyncEnvelope.userInfoKey: try encoded()]
    }

    /// Decodes an envelope out of a received `userInfo`.
    ///
    /// Returns `nil` for anything unrecognized — a foreign dictionary, a corrupt
    /// payload, or a future wire version. A bad message must never take the
    /// session down; the link stays up and the next transfer still lands.
    public static func decode(from userInfo: [String: Any]) -> TallySyncEnvelope? {
        guard let data = userInfo[userInfoKey] as? Data else { return nil }
        guard let envelope = try? makeDecoder().decode(TallySyncEnvelope.self, from: data) else { return nil }
        guard envelope.version <= currentVersion else { return nil }
        return envelope
    }
}
