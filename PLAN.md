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

**Gate 0:** all targets build; TallyKit tests green. API frozen.

## Wave 1 — Surfaces (4 parallel agents + integrator)

| Agent | Scope (spec) | Owns |
|---|---|---|
| `core-ui` | M1: counter, undo, retro-log, live Session card, tab shell, first-run onboarding shell + reusable `PermissionPrimer` component (SPEC §9) | `tally/Features/Tally/`, `tally/Features/Onboarding/`, app entry, tab scaffold |
| `place` | M2: one-shot fix, Home setup, POI inference, check-in sheet, History (Sessions list/detail, materialize-on-touch, notes/pins) | `tally/Features/Place/`, `tally/Features/History/`, `tally/Services/Location/` |
| `widget` | M3: interactive widgets, reconciliation hook | `TallyWidget/` |
| `watch` | M4: watch UI, complications, WatchConnectivity mirroring | `TallyWatch/`, `tally/Services/Connectivity/` |

Cross-wave seam: `core-ui` builds the tab shell and onboarding flow with **named presentation slots** (check-in sheet, History push, onboarding screen 3); `place` builds screens/services against those slot protocols without editing the shell — including the Home-pin screen that fills the onboarding slot. The integrator wires them.

**Gate 1:** merge order `core-ui` → `place` → `widget` → `watch`; build + tests; simulator smoke run of the core loop (launch, log, undo, check-in mock, History).

## Wave 2 — Reflection (4 parallel agents + integrator)

| Agent | Scope (spec) | Owns |
|---|---|---|
| `sync` | M5: flip CloudKit config, venue/Session merge passes, settings toggle | `tally/Services/Sync/`, the one sanctioned TallyKit change (container config flag) |
| `trends` | M6: charts tab, stat tiles, Session share cards | `tally/Features/Trends/`, `tally/Features/ShareCard/` |
| `play` | M7: You tab — points, streak ring, badge case | `tally/Features/You/` |
| `nudge` | M8: notification categories, scheduling, quiet hours, post-first-Session notification primer, full Settings screen (SPEC §9 — including venue management, data export, erase-all) | `tally/Services/Notifications/`, `tally/Features/Settings/` |

**Gate 2:** merge `sync` first (it alone touches TallyKit), then UI streams; build + tests; two-simulator sync sanity check.

## Wave 3 — Proactive (2 parallel agents + integrator)

| Agent | Scope (spec) | Owns |
|---|---|---|
| `radar` | M9: both Bar Radar tiers — frequented derivation, `CLMonitor` geofences, `CLVisit` discovery, gating, suppression, actionable notifications | `tally/Services/Radar/` |
| `insights` | M10: HealthKit read flow, correlation engine + statistical guardrails, Trends insight cards, morning-after chart, weekly insight notification | `tally/Services/Health/`, `tally/Features/Trends/Insights/` |

Both depend on Wave 2 (`nudge`'s notification plumbing and Settings screen; `trends`' tab surfaces). Each adds its own Settings section rows and just-in-time primer via the Wave 1 `PermissionPrimer` component and Wave 0 `PermissionsService`. The insight engine gets its own unit tests with synthetic HealthKit fixtures (guardrail thresholds, insufficient-data silence, effect-size floor).

**Gate 3:** final integration, full test suite, end-to-end simulator pass.

## What agents cannot verify — human QA checklist

Simulators can't exercise these; they need a device pass after Gate 3:

- Location permission upgrade flow (When-In-Use → Always) and real geofence entry/exit at a physical venue
- `CLVisit` discovery latency and false-positive feel in a real bar district
- Watch pairing, WatchConnectivity queuing with phone out of range, complication refresh
- iCloud sync across two signed-in devices; merge after offline logging on both
- HealthKit permission sheet and background delivery
- Notification actions from a locked device; widget intents on the home screen

## Mechanics

- **Agents:** Opus, one worktree each (`isolation: worktree`), prompt = spec sections + ownership map + frozen TallyKit API. Integrator agents run serially at gates.
- **Merge discipline:** integrator merges in the listed order; a conflict outside an agent's owned paths is an ownership-map bug — fix the map, not just the conflict.
- **Definition of done per agent:** owned scope implemented, `xcodebuild build` clean for all targets, unit tests green, no edits outside owned paths (except integrators).
- **Totals:** 14 agents — 1 (Wave 0) + 5 (Wave 1) + 5 (Wave 2) + 3 (Wave 3).

## Sequencing note

Waves preserve the spec's milestone semantics but not its numbering: sync (M5) runs alongside trends/play/nudge (M6–M8) because its only true dependency is the Wave 0 schema, and watch (M4) runs in Wave 1 because WatchConnectivity mirroring doesn't need sync. Nothing in a later wave is load-bearing for an earlier one, so the app is shippable at every gate — same property the milestone list had.
