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

## Wave 4 — Place follow-ups (1 agent, serial) — planned 2026-09-19

Two gaps found in device use after Gate 3, both inside the `place` workstream. They share files (`CheckInPickerModel.swift`, `CheckInPickerSheet.swift`, `VenueAssignmentView.swift`), so one agent does both, search API first.

**Gap A — a Session's venue can only be set from History.** The live Session card on the Tally tab (`LiveSessionCard`) is inert: after "Not now", a step-4 `coordinatesOnly` outcome, or a denied fix, the user has to find the Session under the today count to name the place. SPEC §1 now says the card is tappable and opens the check-in picker.

**Gap B — venue search is weak.** `POISearching.search(_:near:)` is one unfiltered `MKLocalSearch` in a 20 km box, fired only on submit, uncancellable, and only from History. The check-in picker's field never reaches MapKit at all — it filters the 250 m nearby list and offers *Use "X"*, so a bar one street over that you can name is unfindable from the picker. SPEC §2 now specifies type-ahead, bar-first passes with widening, ranking, dedupe, and a distinct failure state.

### Part 1 — Search API (`tally/Features/Place/`)

1. `VenueSearchRequest` (Hashable, Sendable): `query`, `anchor: LocationFix?`, `radiusMeters` (default 5 000), `scope: Scope` (`.bars` = `POISearchService.categories`; `.anyPlace` = no filter).
2. `VenueSearchPlan.passes(for:)` — pure: `[bars@radius, anyPlace@radius, anyPlace@50 km]` with an anchor; `[bars, anyPlace]` unbounded without one. The service runs passes in order and stops at the first non-empty result.
3. `POISearching`: replace `search(_:near:)` with `func search(_ request: VenueSearchRequest) async throws -> [VenueCandidate]`. `nearbyVenues` unchanged. Throw on MapKit failure (a `VenueSearchError`) so callers can tell "nothing" from "broken". `MockPOISearchService` records every request, supports an injected delay and a thrown error, and answers from a per-query fixture map with a default.
4. `VenueSearchRanking.rank(_:query:anchor:)` — pure: match tier (exact name, prefix, contains, other) → bar category before restaurant/other → distance → id. Also `merged(remote:nearby:saved:)`: drop a remote hit that `matches` a nearby row (nearby wins, it was measured from the live fix); a remote hit that matches a saved venue takes the saved name/identity via `CheckInPickerRanking.merging`.
5. `VenueSearchModel` (`@MainActor @Observable`): `query` (set from the field), `results`, `state: .idle | .searching | .results | .empty | .unavailable`, injected `POISearching` and `anchor`. Debounce 300 ms with `Task.sleep`, cancel the previous task on every keystroke, generation counter so a late response never overwrites a newer one, queries under 2 characters clear and idle. Debounce interval injectable for tests.
6. `CheckInPickerRanking.sections` gains `remote: [VenueCandidate]`; with a non-blank query the order is **Search results** (remote, ranked, deduped), **Nearby** (local filter), **Saved venues**. `typedNameCandidate` is matched against the union so a remote exact match suppresses *Use "X"*.
7. `CheckInPickerList` and `VenueAssignmentView` both own a `VenueSearchModel`; the field drives `model.query`; the "Search results" section and the *Search unavailable* row come from `model.state`. `VenueAssignmentView` also gains the *Use "X"* row and switches its distances to `CheckInPickerFormatting`. `ReconciliationPromptView`, `RadarService`, `NotificationCopyTests` compile against the new protocol.

### Part 2 — Venue from the live Session card

1. `CheckInPickerRequest.Origin.session(SessionTarget)` where `SessionTarget: Hashable, Sendable` carries `sessionID`, `eventIDs`, `isMaterialized`, `anchor: LocationFix?` (first located event, reuse `VenueAssignmentView.anchor(for:)`). `CheckInPickerRequest(session:)` uses `session.id` as the request id (one picker per outing), `anchor` as the initial fix, no seeds, no suggestion. `sessionID` returns the target's id; `isFromNotification` is false for this origin.
2. `PlaceCoordinator.presentPicker(forSessionWith id: UUID)` derives the Session, builds the request, clears any `pendingCheckIn` for the same Session, sets `pendingPicker`. `resolvePicker` for `.session`: `VenueWriter.resolveVenue`, `VenueWriter.tag(eventIDs:)`, repoint the materialized `Session` record when `isMaterialized` (mirror `HistoryModel.assignVenue`), `memory.recordConfirmation`. `dismissPicker` for `.session` records nothing — it was the user's own tap, not a prompt. `suppressRow` stays hidden for this origin (the fix may be hours old; suppression is about *here*).
3. `FeatureSlots.assignVenue(toSessionWith id: UUID)` with a no-op default; `PlaceFeatureSlots` forwards to the coordinator. `TallyScreen` passes `onTap: { featureSlots.assignVenue(toSessionWith: session.id) }` to `LiveSessionCard`; the card becomes a `Button` (plain style), a11y trait `.isButton`, hint "Assign a venue"; untagged headline becomes "Session in progress · tap to add where". The picker is presented by the existing `.checkInPicker()` host on the reconciliation modifier at the root — verify that host is attached above the tab shell, and attach `.checkInPicker()` to `RootTabView` if it is not.
4. The header title reads "Where are you?" for `.session` when the Session is still active, "Where was this?" otherwise.

### Tests (`tallyTests/Place/`, Swift Testing, no MapKit)

- `VenueSearchTests`: pass planning; ranking tiers; bar-before-restaurant at equal tier; nearer-first; dedupe against nearby and saved; `merged` keeps the saved name.
- `VenueSearchModelTests`: rapid `query` mutations produce one request (debounce injected to ~10 ms); a slow older response does not overwrite a newer result; clearing the query resets to `.idle`; a thrown error yields `.unavailable`; a one-character query never searches.
- `CheckInPickerTests`: sections ordering with `remote`; a remote exact match suppresses *Use "X"*; `CheckInPickerRequest(session:)` id/fix/`sessionID`/`isFromNotification`.
- `PlaceCoordinatorSessionTests` on `TallyStore.makeInMemoryContainer()`: resolving a `.session` picker tags every event and repoints a materialized record; dismissing records no `CheckInMemory` dismissal; presenting for a Session with an outstanding prompt clears that prompt.
- UI (`TallyUITests`): after logging a drink, tapping `tally.sessionCard` shows `checkIn.picker.root`; "Not now" returns to the counter with the card still present.

### Acceptance

- Type "bowl" in the picker near a bowling alley with no bar of that name: the alley appears under **Search results** with its distance; the *Use "bowl"* row is still offered.
- Type three characters quickly: `MockPOISearchService` saw one request.
- Airplane mode: the picker shows *Search unavailable*, not *No match*.
- Log a drink, dismiss the check-in sheet, tap the live card, pick a venue: the card headline shows the venue, History shows it on the Session, and no second check-in prompt appears for that Session.
- Whole suite green: TallyKit, app unit tests, UI tests. `xcodebuild build` clean for every target.

## Wave 5 — Fibrinolytic suppression: first drink to baseline (3 agents) — planned 2026-09-19

Source: `design/fibrinolytic-suppression-chart.md` (the design is authoritative; this section fixes the API and the split). Phase 1 is serial; Phase 2 runs two agents in parallel on disjoint paths once Phase 1 is on `main`.

### Phase 1 — `TallyKit` shared timeline (1 agent, serial)

Owned: `TallyKit/Sources/TallyKit/Recovery/`, `TallyKit/Tests/TallyKitTests/`. Raw model behaviour (`suppressionIndex`, `curve`, `projectedPeak`, `baselineReturn`, `classify`) is unchanged; every existing test still passes byte-for-byte.

1. **Precomputed weights.** `FibrinolysisModel` gains `WeightedDrink { id, timestamp, weight }`, `weightedDrinks(_ events:) -> [WeightedDrink]` (compression weight computed once per drink over the sorted alcoholic list), and `suppressionIndex(at:weighted:)` / `curve(from:to:step:weighted:)`. The existing event-based overloads become thin wrappers so results are identical.
2. **`SuppressionEpisode`** (`Hashable, Sendable`): `start: Date` (first drink), `drinks: [WeightedDrink]`, `lastDrink: Date`, `baselineReturn: SuppressionEndpoint`, `isComplete(asOf:)`. `SuppressionEndpoint` is `.projected(Date)`, `.returned(Date)`, or `.unavailable` (computation limit hit — never a fabricated zero).
3. **`SuppressionEpisodes.partition(events:now:model:)`** — the design's rules 1–4. Alcoholic drinks with `timestamp <= now` only. Each drink joins the open episode if it lands before that episode's current return time, otherwise it starts a new one. Return search: from the last included drink's peak (`timestamp + peakDelay`), step 30 min on the combined raw curve of **all** retained drinks until the value is at or below `baselineThreshold`, bracket, then bisect to 60 s; cap the walk at 14 days → `.unavailable`. Retained context: drinks from earlier episodes keep contributing to the curve (a boundary is a display boundary). Pruning tolerance, documented as a constant: a drink is dropped only when its maximum possible pulse (`ceiling`) has decayed below `0.05` index points before the episode start, i.e. `~88 h`; use `pruneHorizon = 96 h`.
4. **`SuppressionTimeline`** (`Hashable, Sendable`) — the one thing views draw. Fields: `episode`, `now`, `range: ClosedRange<Date>` (start = first drink − pad, end = return + pad, pad = 5 % of span clamped to 15–60 min; an `.unavailable` end uses the last sample), `samples: [Sample { date, raw, display }]` with `display = max(0, raw − baselineThreshold)`, `drinkMarkers: [DrinkMarker { id, date, weight }]`, `peak: Peak { date, raw, display, plateauEnd: Date? }` (overall episode maximum, past or future; plateau when raw ≥ ceiling − 0.01 for more than one sample), `nowValue: Sample?` (nil when now is outside the range), `state: State` (`riseAhead`, `rising`, `easing`, `atBaseline`, from the local slope at now, ±5 min), `isComplete`, `isHistoryComplete`, `retainedUntil: Date` (later of last drink + 24 h and return + 24 h). Sampling: 15 min step up to 48 h of range, 30 min to 5 days, 60 min beyond; anchor samples always inserted exactly: episode start, every drink's onset and peak instant, now, the overall peak, the baseline crossing, and the range end. Decimation for drawing is the view's job, never here.
5. **Builders.** `SuppressionTimeline.make(now:events:model:historyStart:) -> SuppressionTimeline?` returns the active episode, else the most recently completed one while `now < retainedUntil`, else nil. Empty or NA-only logs → nil. `historyStart` is the earliest timestamp the caller fetched (nil = whole log); `isHistoryComplete` is false when the episode's first drink is within `pruneHorizon` of it. `SuppressionTimeline.make(now:events:model:containing eventID:)` returns the episode containing that event regardless of retention (Session detail). Future-dated drinks are ignored by both.
6. **Tests** (`SuppressionTimelineTests`): single drink immediately after logging (start, rise ahead, peak at +4 h, return projected, samples end at zero, end sample present); next-morning view keeps the same start and the passed peak; two-day continuous episode > 66 h stays one episode; a drink before return extends, a drink after return starts a new episode; a temporary dip with a pending rise does not complete; capped plateau reports first occurrence and `plateauEnd`; multiple local peaks with one overall peak; incomplete history flag; `.unavailable` when the walk cap is hit (use a configuration with an absurd half-life); retention window arithmetic; `containing:` picks the right episode; weighted overloads equal the event overloads at 1e-9 on a 40-drink log.

### Phase 2a — App card, expanded chart, Session detail, docs (1 agent, worktree)

Owned: `tally/Features/Tally/SuppressionCurveCard.swift` (+ new files beside it), `tally/Features/Tally/TallyScreen.swift`, `tally/Features/History/SessionDetailView.swift` (+ one new file), `tally/Features/Settings/RecoveryExplainer.swift`, `tallyTests/Recovery/`, `SPEC.md` §4.

1. `SuppressionSummary` is rebuilt on `SuppressionTimeline` (drop `lookBack`/`lookAhead`/`relevanceWindow`/the 66 h cutoff; `relevantEvents` goes). Copy, view-free and tested: header **Modeled fibrinolytic suppression**, state word (**Rise ahead / Rising / Easing / At modeled baseline**), three facts **First drink** (logged precision; **Available history** when incomplete), **Peak / Peaked**, **Baseline / Returned** (hour-rounded, tilde, day-aware), forecast footnote **Based on logged drinks; assumes no additional drinks**, info text "Zero on this chart means the model is within its baseline range. It is not a measured biological value." Never a percentage; chart numbers are display values.
2. Day-aware time: `SuppressionTime.approximate` gains a calendar relationship (today / tomorrow / weekday / weekday + date beyond 6 days) computed from `calendar.isDateInToday` etc., not hour thresholds. Existing tests updated to the new contract; 12/24 h, midnight, DST cases added.
3. Card: chart height 150 pt, x-domain = `timeline.range`, y-domain 0…peak display × 1.15 (fixed for the episode, never rescaled by the clock), solid line up to now and dashed after, amber stroke always (neutral only for a fully completed curve's future-free tail is *not* required — keep amber; the design forbids draining the history), start marker, drink ticks along the bottom merged into a count when closer than 3 % of the range, peak marker, Now rule + point, endpoint label **0 · modeled baseline**, a completed curve replaces the Now rule with **Returned to modeled baseline ~[time]**. 4–6 x labels via `AxisMarks(values:)` computed from the range with day labels at midnight crossings. Three facts row under the chart. VoiceOver label covers start, peak, current state, return.
4. Expanded sheet (`SuppressionDetailSheet`): same timeline, taller, `chartOverlay` drag/tap inspection showing display value + time, plateau interval described, an accessible alternative (a stepper through the anchor samples or `accessibilityAdjustableAction`).
5. Retention/refresh: card renders while `make` returns non-nil; ticks every 60 s; `refreshKey` is a hash of alcoholic event ids + timestamps + types (not `count`); refresh on `scenePhase == .active`.
6. Session detail: a **Recovery timeline** row (recovery on, Session has alcoholic drinks) opens the same sheet via `make(containing:)` with the Session's event ids highlighted (brighter ticks).
7. SPEC §4: document the baseline-relative display scale, the episode definition, and the completed-card retention. Explainer: one new point, "What zero means".

### Phase 2b — Widget parity (1 agent, worktree)

Owned: `TallyWidget/SuppressionCurveView.swift`, `TallyWidget/TallyWidgetEntry.swift`, `TallyWidget/TallyWidgetProvider.swift`.

1. `SuppressionSnapshot` becomes a thin wrapper over `SuppressionTimeline` (drop the 3 h/12 h window, `relevanceWindow`, its own phase logic). Samples decimated to ≤ 64 points for drawing while keeping the anchor samples; `nowFraction` from the timeline range; caption "State · baseline ~time" using the same day-aware wording as the app (duplicate the small formatter, not the tests — the widget has no test target).
2. Fetch: history for the suppression snapshot starts at `now − 30 days` (separate from the 7-day sparkline window); pass `historyStart` so `isHistoryComplete` is honest. Timeline entries: hourly to the episode's return + 24 h, capped at 48 entries, plus the midnight entry; `policy: .after(retainedUntil)`.
3. Compact mini-curve: full episode shape, Now rule, and a one-line baseline caption; **Returned ~time** when complete.

### Integration and acceptance

- Phase 1 lands on `main` before Phase 2 branches. Each Phase 2 agent hands back a worktree with all targets building and `tallyTests` + `TallyKitTests` green; the integrator merges 2a then 2b and runs the UI suite.
- Acceptance is the design doc's list. Simulator-verifiable items: every "Tests cover…" bullet, the end sample present and at zero, retention arithmetic, empty/NA-only logs show no chart, undo/edit recompute (unit tests over `make` with edited logs). Device/visual items go to the human QA checklist.

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
