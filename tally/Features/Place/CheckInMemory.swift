import Foundation

/// "You get asked once per outing, not per drink" (SPEC §2 step 3).
///
/// Two facts per Session, both of which suppress the prompt:
/// * **confirmed** — a venue was chosen, so later drinks auto-tag silently;
/// * **dismissed** — "Not now", which "doesn't re-prompt this Session".
///
/// Persisted, deliberately: a Session runs for hours and the app gets killed in
/// pockets. Losing a dismissal on relaunch would re-ask the one question the
/// user already answered. Keyed by the derived Session ID, which is stable
/// across launches and devices (SPEC §2).
@MainActor
public final class CheckInMemory {

    public enum Decision: Hashable, Sendable {
        /// A venue was confirmed for this Session.
        case confirmed(UUID)
        /// The sheet was waved off. Stay quiet for the rest of the outing.
        case dismissed
    }

    private struct Entry: Codable {
        var venueID: UUID?
        var recordedAt: Date
    }

    private static let storageKey = "tally.place.checkInMemory"

    /// Enough to cover any plausible backlog of open Sessions without letting
    /// the blob grow without bound.
    private static let maxEntries = 60

    private let defaults: UserDefaults
    private var entries: [UUID: Entry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(from: defaults)
    }

    public func decision(for sessionID: UUID) -> Decision? {
        guard let entry = entries[sessionID] else { return nil }
        if let venueID = entry.venueID { return .confirmed(venueID) }
        return .dismissed
    }

    public func recordConfirmation(venueID: UUID, for sessionID: UUID) {
        entries[sessionID] = Entry(venueID: venueID, recordedAt: Date())
        persist()
    }

    public func recordDismissal(for sessionID: UUID) {
        entries[sessionID] = Entry(venueID: nil, recordedAt: Date())
        persist()
    }

    public func forget(sessionID: UUID) {
        entries.removeValue(forKey: sessionID)
        persist()
    }

    public func reset() {
        entries = [:]
        persist()
    }

    // MARK: Storage

    private func persist() {
        if entries.count > Self.maxEntries {
            let keep = entries
                .sorted { $0.value.recordedAt > $1.value.recordedAt }
                .prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let encodable = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [UUID: Entry] {
        guard
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }

        return decoded.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }
}
