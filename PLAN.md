# Tally — Implementation Plan (parallel agents)

Execution plan for SPEC.md using parallel Opus agents in isolated git worktrees. The spec's milestones (M1–M10) are ordered for shippability; this plan reorders them into **dependency waves** so independent workstreams run concurrently, with serial integration gates between waves.

## Why waves, and the two rules that make parallelism safe

Parallel agents on an Xcode project fail in two predictable ways: colliding edits to `project.pbxproj`, and drifting assumptions about shared types. Both are handled structurally:

1. **Only Wave 0 touches project structure.** Targets, entitlements, capabilities, and the App Group are all created up front. Later waves add source files only — the project uses Xcode's synchronized folder groups, so new files under an owned directory appear in the build without touching `project.pbxproj`.
2. **Contracts first, then freeze.** Wave 0 builds `TallyKit` (a local Swift package): the SwiftData models, the Session deriver, the scoring engine, the store factory, and the shared App Intents. Its public API is **frozen during each wave** — agents consume it, never edit it. API changes happen only at integration gates.

Every agent works in its own worktree, owns an exclusive directory set (below), and must hand back a worktree where `xcodebuild build` and the unit test suite pass. An integrator merges each wave in a fixed order and resolves anything cross-cutting.

## Wave 0 — Foundation (serial, 1 agent)

The only wave allowed to touch targets and the only one that edits TallyKit's API.

- Add targets: widget extension, watchOS app. Configure App Group, capabilities (location, notifications, HealthKit placeholders), entitlements.
- **TallyKit package:**
  - Models: `DrinkEvent`, `Venue`, `Session`, `SuppressedPlace` — CloudKit-safe per SPEC §1 (no unique constraints, optional/defaulted attributes, optional relationships with inverses, string-raw enums).
  - `ModelContainer` factory: App Group URL, `cloudKitDatabase: .none` (flipped in Wave 2).
  - `SessionDeriver`: the deterministic Session computation (SPEC §2 boundaries, first-event-UUID identity, materialized-record precedence).
  - `ScoringEngine`: spacers, points, streaks, badge predicates (SPEC §3).
  - `LogDrinkIntent` App Intent (shared by app, widget, watch).
  - `PermissionsService`: live status introspection + request wrappers for location (When-In-Use/Always), notifications, and HealthKit — the shared contract behind every primer and Settings status row (SPEC §9).
- **Test suite is the deliverable:** SessionDeriver determinism (same events → same Sessions on repeated runs and shuffled insert order), boundary cases (3 h gaps, venue changes, retro-logs, undo of first event), materialization precedence, scoring correctness, UUID-dedupe idempotence.

**Gate 0 — acceptance:**

- All targets build (app, widget extension, watch app, TallyKit tests).
- TallyKit suite green on these named invariants:
  - Deriver determinism: shuffled insert order produces an identical Session list with identical IDs.
  - Boundaries: 3 h gaps open/close Sessions; a venue change splits; a retro-logged earlier event changes the derived ID only for unmaterialized Sessions.
  - Materialization precedence: events inside a materialized window belong to it; derivation runs over the remainder; no event edit can dangle a materialized reference.
  - Scoring: spacer detection, +10/+25/+50 awards, ratio streaks including dry-day extension.
  - Dedupe: double-delivered event UUIDs merge idempotently.
  - CloudKit-safety audit test: no unique attributes, everything optional/defaulted, relationships have inverses.
- `PermissionsService` ships behind a protocol with a mock, so UI agents can test permission states without dialogs.
- On pass: tag `wave0-api`; TallyKit API frozen.

## Wave 1 — Surfaces (4 parallel agents + integrator)

| Agent | Scope (spec) | Owns |
|---|---|---|
| `core-ui` | M1: counter, undo, retro-log, live Session card, tab shell, first-run onboarding shell + reusable `PermissionPrimer` component (SPEC §9) | `tally/Features/Tally/`, `tally/Features/Onboarding/`, app entry, tab scaffold |
| `place` | M2: one-shot fix, Home setup, POI inference, check-in sheet, History (Sessions list/detail, materialize-on-touch, notes/pins) | `tally/Features/Place/`, `tally/Features/History/`, `tally/Services/Location/` |
| `widget` | M3: interactive widgets, reconciliation hook | `TallyWidget/` |
| `watch` | M4: watch UI, complications, WatchConnectivity mirroring | `TallyWatch/`, `tally/Services/Connectivity/` |

Cross-wave seam: `core-ui` builds the tab shell and onboarding flow with **named presentation slots** (check-in sheet, History push, onboarding screen 3); `place` builds screens/services against those slot protocols without editing the shell — including the Home-pin screen that fills the onboarding slot. The integrator wires them.

**Gate 1 — acceptance** (merge order `core-ui` → `place` → `widget` → `watch`; build + unit tests, then these spec behaviors verified on simulator):

- §1: a tap increments and survives relaunch; undo removes the most recent event of that type today and no-ops at zero; long-press retro-logs at a custom time with no location.
- §1–2: the live Session card appears after logging with venue, counts, and elapsed time.
- §2: with a mocked fix and POI result, the check-in sheet fires on a single confident candidate; confirming silently auto-tags subsequent drinks in the Session; dismissing never re-prompts that Session.
- §2: with location denied, logging still works and events simply have no coordinates — the tap is never blocked.
- §9: first run shows exactly three screens, each skippable, ending on the counter; the in-app primer always precedes the system location dialog.
- §6: a widget tap logs without launching the app; with no fix within ~5 s the event saves as `source = .widget` with no coordinates, and reconciliation is offered on next app open.
- §7: a watch log made while the phone is unreachable queues and mirrors on reconnect; double delivery dedupes by UUID.
- XCUITest suite (created by `core-ui`, run at every subsequent gate): launch → log → undo → History → back.

## Wave 2 — Reflection (4 parallel agents + integrator)

| Agent | Scope (spec) | Owns |
|---|---|---|
| `sync` | M5: flip CloudKit config, venue/Session merge passes, settings toggle | `tally/Services/Sync/`, the one sanctioned TallyKit change (container config flag) |
| `trends` | M6: charts tab, stat tiles, Session share cards | `tally/Features/Trends/`, `tally/Features/ShareCard/` |
| `play` | M7: You tab — points, streak ring, badge case | `tally/Features/You/` |
| `nudge` | M8: notification categories, scheduling, quiet hours, post-first-Session notification primer, full Settings screen (SPEC §9 — including venue management, data export, erase-all) | `tally/Services/Notifications/`, `tally/Features/Settings/` |

**Gate 2 — acceptance** (merge `sync` first — it alone touches TallyKit — then the UI streams):

- §8: with two simulators on one iCloud account, an event logged on A appears on B; the same venue created on both merges to one, with events and materialized Sessions repointed. Signed-out stays fully functional.
- §4: Trends renders without crashing on an empty store, a single event, and a 90-day fixture; the 7-day average matches fixture math exactly.
- §2: sharing materializes the Session; the share card's counts, duration, and badges match the fixture (snapshot test).
- §3: You-tab points, streak, and badge states match `ScoringEngine` output for the same fixture.
- §5: each notification category schedules only when its toggle is on; quiet hours suppress everything except Bar Radar categories; the pacing nudge fires on a 3-drinks-in-90-min fixture; streak protection fires on the would-break-streak evening fixture.
- §9: every Settings value round-trips (change → kill app → relaunch → persisted); export yields parseable CSV/JSON containing every event; erase-all double-confirms, wipes the store, and clears CloudKit when sync is on.
- XCUITest extended: Trends renders, Settings toggles flip, You tab shows.

## Wave 3 — Proactive (2 parallel agents + integrator)

| Agent | Scope (spec) | Owns |
|---|---|---|
| `radar` | M9: both Bar Radar tiers — frequented derivation, `CLMonitor` geofences, `CLVisit` discovery, gating, suppression, actionable notifications | `tally/Services/Radar/` |
| `insights` | M10: HealthKit read flow, correlation engine + statistical guardrails, Trends insight cards, morning-after chart, weekly insight notification | `tally/Services/Health/`, `tally/Features/Trends/Insights/` |

Both depend on Wave 2 (`nudge`'s notification plumbing and Settings screen; `trends`' tab surfaces). Each adds its own Settings section rows and just-in-time primer via the Wave 1 `PermissionPrimer` component and Wave 0 `PermissionsService`. The insight engine gets its own unit tests with synthetic HealthKit fixtures (guardrail thresholds, insufficient-data silence, effect-size floor).

**Gate 3 — acceptance:**

- §2 Tier 1 (simulated location injection): geofence entry fires the arrival notification with both actions; the +1 action logs an auto-tagged event without foregrounding the app; the dwell follow-up is cancelled by any log or an exit event; one follow-up max per visit; exit + re-entry within 2 h doesn't re-prompt.
- §2 Tier 2 (simulated visit events): a visit at a single nightlife POI fixture prompts; an ambiguous POI cluster stays silent; prompts respect discovery hours and the 3-per-week cap; "Not a bar" writes a `SuppressedPlace` that permanently silences the spot; a third confirmed Session at a discovered venue promotes it into the geofence set.
- §4 (synthetic HealthKit fixtures): under-threshold data produces *no* insight; a ≥ 8/≥ 8-day fixture with a ≥ 20% effect produces a card whose numbers match the fixture; revoking the read permission removes every insight surface and nothing else.
- §5: activity-insight notifications cap at one per week.
- Full unit + XCUITest suites green; then the human QA checklist below runs on a physical device.

## What agents cannot verify — human QA checklist

Simulators can't exercise these; they need a device pass after Gate 3:

- Location permission upgrade flow (When-In-Use → Always) and real geofence entry/exit at a physical venue
- `CLVisit` discovery latency and false-positive feel in a real bar district
- Watch pairing, WatchConnectivity queuing with phone out of range, complication refresh
- iCloud sync across two signed-in devices; merge after offline logging on both
- HealthKit permission sheet and background delivery
- Notification actions from a locked device; widget intents on the home screen

## Failure & rollback rules

- **A failing workstream never blocks its wave.** The integrator merges passing streams in the listed order and skips the failure — ownership isolation is what makes the skip clean.
- **One fix cycle, then re-scope.** A failed stream goes back to its agent once, with the concrete failing acceptance items. If it fails again, shrink its scope to the subset that passes and carry the remainder as a new workstream in the next wave.
- **Each stream lands as a single merge commit**, so a regression discovered after a gate is handled by reverting that one commit, fixing in the worktree, and re-landing — never by patching on `main`.
- **Acceptance items are never relaxed to pass a gate.** If an item is wrong, that's a SPEC.md change first, plan change second, and only then a gate change.
- Each passed gate is tagged (`wave0` … `wave3`) so any regression bisects to a wave boundary.

## Mechanics

- **Agents:** Opus, one worktree each (`isolation: worktree`), prompt = spec sections + ownership map + frozen TallyKit API + that wave's acceptance checklist (agents build against the gate, not just the spec). Integrator agents run serially at gates.
- **Merge discipline:** integrator merges in the listed order; a conflict outside an agent's owned paths is an ownership-map bug — fix the map, not just the conflict.
- **Definition of done per agent:** owned scope implemented, `xcodebuild build` clean for all targets, unit tests green, the wave's acceptance items covering the agent's scope demonstrably pass in its worktree, no edits outside owned paths (except integrators).
- **Totals:** 14 agents — 1 (Wave 0) + 5 (Wave 1) + 5 (Wave 2) + 3 (Wave 3).

## Sequencing note

Waves preserve the spec's milestone semantics but not its numbering: sync (M5) runs alongside trends/play/nudge (M6–M8) because its only true dependency is the Wave 0 schema, and watch (M4) runs in Wave 1 because WatchConnectivity mirroring doesn't need sync. Nothing in a later wave is load-bearing for an earlier one, so the app is shippable at every gate — same property the milestone list had.
