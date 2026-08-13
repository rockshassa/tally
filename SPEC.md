# Tally — Drink Counter Spec

A one-tap counter for alcoholic drinks with automatic time/location capture, venue inference, non-alcoholic drink gamification, trend visualization, notifications, a home-screen widget, and Apple Watch entry.

**Platform:** native iOS 26+ / watchOS 26+, SwiftUI, Liquid Glass design language. Data layer is CloudKit-compatible from day one so iCloud sync is a switch-flip, not a migration (§7).

---

## 1. Core logging

The main screen is a counter, nothing else:

- **Big primary button: +1 alcoholic drink.** Tapping it creates a `DrinkEvent` with the current timestamp and a one-shot location fix.
- **Decrement (−)** removes the *most recent* alcoholic drink event from today (undo semantics — it deletes the event, including its location/venue data). No-op at zero.
- **Secondary button: +1 non-alcoholic drink** (water, soda, NA beer — one bucket, no subtypes in v1). Same decrement semantics.
- Haptic + count animation on tap; today's tallies always visible.
- While a Session is active (§2), the counter shows a live Session card: venue, counts, spacers, elapsed time.
- **Retro-logging:** long-press either button to add a drink at a custom time (no location attached, since we can't know where you were).

### Data model

```
DrinkEvent
  id            UUID              // app-level identity (see CloudKit rules below)
  type          .alcoholic | .nonAlcoholic
  timestamp     Date
  latitude/longitude  Double?     // nil if permission denied or retro-logged
  horizontalAccuracy  Double?
  venue         Venue?            // optional relationship, set after inference/check-in
  source        .app | .widget | .watch

Venue
  id            UUID
  name          String            // "The Anchor", "Home"
  category      .bar | .restaurant | .home | .other
  latitude/longitude  Double
  radiusMeters  Double            // geofence, default 75 (home: 100)
  source        .userDefined | .mapKitPOI
  mapItemID     String?           // MapKit identifier for POI venues
  muted         Bool              // default false; opts this venue out of Bar Radar (§2)

Session (materialized-on-touch — most Sessions are never persisted; see §2)
  id            UUID              // the deterministic derived ID, captured at materialization
  startedAt     Date
  endedAt       Date
  venue         Venue?
  note          String?           // "Dave's birthday"
  pinned        Bool              // default false

SuppressedPlace (discovery-tier "don't ask here" — see §2)
  id            UUID
  latitude/longitude  Double
  radiusMeters  Double            // default 75
  mapItemID     String?
```

Storage: **SwiftData in an App Group container** shared by the app and widget extension.

**CloudKit-compatibility rules — enforced from M1** even though sync ships later:

- No `@Attribute(.unique)` constraints (CloudKit doesn't support them). Identity is the app-level `id` UUID field; all merges dedupe by it.
- Every attribute is optional or has a default; every relationship is optional with an explicit inverse.
- Enums stored as raw-value strings with defaults.
- **Derive, don't store, aggregates.** Points, streaks, badges, and Session groupings are recomputed from the event log, never persisted — so there's no aggregate state to conflict-resolve when devices merge. The one exception is materialized `Session` records (§2), which store identity and user annotations — never counts, which stay derived.
- Venue dedupe is an app-level concern: if two devices create the same bar (matched by `mapItemID`, or by name + proximity for user-defined venues), a post-sync merge pass collapses them and repoints events and materialized Sessions.

---

## 2. Location capture & venue inference

- **When-In-Use** location permission only. No continuous tracking, no background location — a single one-shot fix per log event (battery- and privacy-cheap).
- If permission is denied, logging still works; events just have no location and trends lose the venue dimension. Never block the core tap.

**Inference pipeline** (runs after each fix):

1. **User venues first.** If the fix falls inside a saved venue's geofence (Home, or a previously confirmed bar), auto-tag the event. No prompt.
2. **POI lookup.** Otherwise run an `MKLocalSearch` (MapKit points-of-interest) around the fix, filtered to nightlife/bar/brewery/restaurant/cafe categories within ~75 m.
3. **Check-in prompt.** If there's a single confident candidate (nearest POI, distance < accuracy + 50 m), show a non-blocking sheet: *"Looks like you're at **The Anchor** — check in?"* Confirm / pick another nearby result / dismiss.
   - Confirming saves the venue and tags the event. **Subsequent drinks within the same Session auto-tag silently** — you get asked once per outing, not per drink.
   - Dismissing tags nothing and doesn't re-prompt this Session.
4. **Ambiguous or no results:** tag with raw coordinates only; the history view lets you assign a venue later.

**Home** is a user-defined venue set during onboarding ("Set my home location"), not inferred — inferring where someone sleeps is a privacy footgun. Drinks at home are tagged without any prompt.

### Sessions

**"Session"** is the product's name for one outing, and the term the UI, notifications, trends, and badges all use.

- **Boundaries:** a Session opens with the first drink after ≥ 3 h of inactivity. Consecutive events belong to the same Session while each is within 3 h of the previous and inside the same venue geofence (or has no venue). A Session closes 3 h after its last drink — its recorded end time is that last drink's timestamp — or immediately when a Bar Radar exit event fires, whichever comes first.
- **What a Session carries:** venue, start/end, duration, alcoholic and NA counts, spacers, points earned.
- **Where it surfaces:** the live card on the Tally screen while active (*"Session at The Anchor — 3 drinks · 1 spacer · 1 h 40 m"*); History is a list of past Sessions, each opening into its drink timeline; Trends reports per-Session stats (§4).
- **Implementation — materialize-on-touch:** Sessions are computed deterministically from the event log, keyed by their first event's UUID — every device derives the identical Session list from the same events, so by default nothing is stored and there's zero sync surface. The first time a Session is *touched* — annotated, pinned, or shared — the app persists a lightweight `Session` record (§1) capturing that ID, its boundaries, and venue. From then on the record owns the identity: later event edits (undoing the first drink, retro-logging, timestamp changes) can no longer dangle a reference. Events falling inside a materialized Session's window belong to it; derivation runs over the remainder. Two devices materializing the same Session produce the same deterministic ID, so sync dedupes by UUID like everything else.
- **Notes & pins:** any Session in History can be given a note (*"Dave's birthday"*) or pinned; either action materializes it.
- **Sharing:** share-sheet snapshot — a rendered card (image or text) with venue, date, counts, spacers, duration, and badges earned. Sharing materializes the Session; the card itself is a static export, since recipients don't have your data and there's no backend to host a live view.
- Manual split/merge of Sessions is out of scope for v1.

### Bar Radar — proactive venue detection

Bar Radar notices you're somewhere worth tracking and prompts before you've logged anything. It has **two tiers sharing one prompt-and-suppression machinery**: precise geofences at bars you frequent, and opt-in discovery of bars you've never logged. This is the one feature that needs **Always** location — everything else runs on When-In-Use — so it's a separate, clearly-explained opt-in that triggers the permission upgrade only when enabled.

**Tier 1 — Frequented venues (geofences)**

- **Frequented** = a venue with ≥ 3 Sessions in the trailing 90 days, derived from the event log (never stored, per §1). Home and muted venues are excluded.
- The app registers OS geofences (`CLMonitor` circular conditions) for the top frequented venues by recency, staying under the system's ~20-region cap. Geofence evaluation is done by the OS on-device — the app receives entry/exit events only, never a location stream.
- **On entry:** auto check-in to the venue (it's known — no confirmation sheet needed) and fire a local notification: *"Looks like you're at **The Anchor** — start a Session?"* with actions:
  - **+1 drink** — logs directly from the notification, opening the Session auto-tagged to the venue, without launching the app.
  - **Not drinking tonight** — suppresses all further prompts for this visit.
- **Dwell follow-up:** at entry, schedule a second notification for +45 min (configurable): *"Still at The Anchor — start a Session?"* It's cancelled if any drink gets logged or the exit event fires first. **One follow-up maximum per visit** — after that, silence.
- Exit followed by re-entry within 2 h counts as the same visit (stepping outside shouldn't re-trigger the arrival prompt).

**Tier 2 — Discovery ("Discover new bars", its own sub-toggle, on by default when Bar Radar is enabled)**

- **Mechanism:** OS visit monitoring (`CLVisit`) — the low-power service that fires when the system decides you've arrived somewhere and lingered. On a visit event, the app runs the same MapKit POI lookup as check-in; a **single confident nightlife candidate** within the visit's accuracy radius fires the same *"start a Session?"* prompt. No candidate, or an ambiguous cluster → the event is discarded on the spot.
- **Expected latency:** visit events land 10–20 minutes into a stay (occasionally on departure). Discovery behaves like a dwell reminder, not an arrival ping — geofence immediacy stays exclusive to Tier 1.
- **False-positive gating:** plausible hours only (default 4 pm–2 am, configurable), max 3 discovery prompts per week, never inside the Home geofence, never at suppressed places.
- **"Not a bar / don't ask here"** is a first-class action on discovery prompts — it writes a `SuppressedPlace` (§1) and that spot goes permanently quiet. Two plain dismissals at the same spot auto-suppress it.
- **Graduation:** a confirmed Session at a discovered bar creates the Venue and counts toward frequented status — discovery is Tier 1's on-ramp. Three Sessions later the bar earns its own geofence.

Controls: the global Bar Radar toggle governs both tiers; discovery is additionally gated by its own sub-toggle. Per-venue mute (also offered on the arrival notification after repeated dismissals) covers Tier 1; neither tier ever applies to Home.

---

## 3. Non-alcoholic drinks & game mechanics

Design rule: **mechanics only ever reward NA drinks and moderation — nothing ever awards points for alcohol.**

- **Spacers.** An NA drink logged between two alcoholic drinks in a Session is a "spacer." Spacers are the core scoring unit.
- **Points.** +10 per NA drink, +25 bonus per spacer, +50 for finishing a Session at ≥ 1:1 NA-to-alcohol ratio.
- **Streaks.** Daily streak for hitting your ratio goal (default 1:1, configurable). Dry days extend the streak automatically.
- **Badges** (examples): *Pacer* — alternated all night; *Designated Legend* — a Session at a bar with zero alcoholic drinks; *Hydration Week* — 7-day ratio streak; *Dry Spell* — 3/7/30 dry days.
- Progress lives on a lightweight "You" tab: points, current streak, badge case. No leaderboards, no social — this data is nobody else's business.
- All of it recomputed from the event log, so watch- and phone-logged drinks contribute identically.

---

## 4. Trends & visualization

A "Trends" tab built on Swift Charts:

- **Bar chart** of drinks per day/week/month (segmented control), alcoholic vs NA stacked.
- **Rolling 7-day average** line overlay — the headline trend signal.
- **Ratio over time** (NA : alcoholic).
- **By-venue breakdown** — where your drinks happen (Home vs bars vs everything else).
- **Time-of-day heatmap** (hour × weekday).
- **Session stats:** average drinks per Session, Sessions per week, longest Session, best-paced Session (highest spacer ratio).
- Stat tiles: this week vs last week, longest dry streak, current streak, most frequent venue.

### Health insights (HealthKit)

Opt-in cross-reference of drinking against activity data, to answer one question: **is drinking eating into your activity?**

- **Reads** (each individually grantable in the HealthKit permission sheet): exercise minutes, active energy, step count, and workouts. Sleep and resting heart rate are deliberately out of scope for v1 (see Open questions).
- **Correlation engine — runs entirely on-device**, comparing you only against your own baseline:
  - *Morning-after:* activity on days following a Session of ≥ 2 alcoholic drinks (threshold configurable) vs days following dry days.
  - *Weekly drift:* trailing 4-week exercise trend against drink totals — flags when a rising drink trend co-occurs with a falling activity trend.
  - *Workout displacement:* whether workout frequency drops in weeks with more Sessions.
- **Statistical guardrails:** an insight is shown only when there's enough data (≥ 8 drinking-day and ≥ 8 dry-day comparisons in the trailing 90 days) *and* the effect is meaningful (≥ 20% difference). Weak or noisy correlations produce silence, not filler — no insight is better than a spurious one.
- **Framing:** insights state correlations in your own numbers and never claim causation or prescribe: *"After 3+ drink Sessions, your next-day exercise averages 12 min vs your usual 34."* The §5 tone rules apply — facts, no shame.
- **Surfaces:** insight cards at the top of the Trends tab; a morning-after comparison chart (drinking-day-after vs dry-day-after activity, side by side); and the Activity insight notification category (§5).
- **Refresh:** HealthKit background delivery (`HKObserverQuery`) re-runs the engine as new activity data arrives; insights are recomputed, never persisted, per §1's derive-don't-store rule.
- **Absence is fine:** no HealthKit permission, or no correlation found, simply means the cards don't appear. Nothing else in the app depends on this feature.

---

## 5. Notifications

All local (no server), **opt-in per category**, with quiet-hours respect. Notifications mirror to the watch automatically when the phone is locked — the pacing nudge landing on the wrist mid-session is the point.

| Category | Trigger | Example |
|---|---|---|
| Weekly digest | Sunday evening | "12 drinks this week, down 3 from last. 7-day avg: 1.7/day." |
| Trend alerts | Sustained change in 7-day average | "Third week trending down — nice." |
| Pacing nudge | 3+ alcoholic drinks within 90 min, in-Session | "Time for a spacer? +25 pts." |
| Streak protection | Evening of a day that would break a streak | "5-day streak on the line — log some water." |
| Bar Radar arrival | Geofence entry at a frequented bar (§2) | "Looks like you're at The Anchor — start a Session?" |
| Bar Radar dwell | 45 min after arrival, still there, nothing logged | "Still at The Anchor — start a Session?" |
| Bar Radar discovery | Visit detected at a bar never logged before (§2), max 3/week | "Looks like you're at The Salty Dog — start a Session?" |
| Activity insight | New qualifying correlation from the health-insights engine (§4), at most one per week | "Your exercise minutes run 40% lower in weeks with 10+ drinks." |

Tone throughout: neutral-to-encouraging, never shaming. Upward-trend alerts state facts ("up 20% vs last month") without judgment. Quiet hours apply to every category except the Bar Radar ones — bar hours *are* quiet hours, and those prompts are the feature.

---

## 6. Widget

WidgetKit + App Intents (interactive buttons):

- **Small (home screen):** today's counts + two buttons: +1 alcoholic, +1 NA. Taps log directly from the widget without opening the app.
- **Medium:** the above plus a 7-day sparkline.
- **Lock screen (circular/inline):** today's count, tap opens the app.

**Location caveat:** widget-originated logs run in the widget extension, where a location fix is best-effort. If the fix can't be obtained within ~5 s, the event saves with `source = .widget` and no coordinates, and the app **reconciles on next open** — offering venue tagging for recent untagged widget events. The count must never wait on GPS.

---

## 7. Watch app

watchOS 26+ SwiftUI app — logging from the wrist is the fastest path to the "one tap, no friction" goal.

- **UI:** a single screen mirroring the phone's counter — today's counts, +1 alcoholic, +1 NA, and an undo affordance (swipe on the count). Nothing else; no trends, no settings on the watch.
- **Complications** (WidgetKit accessory families + Smart Stack): today's count at a glance, tap to open the logging screen.
- **Location:** the watch attempts its own one-shot fix (works phone-free on GPS models). Venue inference and check-in prompts stay on the phone — watch events land untagged and go through the same reconciliation flow as widget events (§6) on next phone-app open.
- **Data transport:**
  - The watch app keeps its **own SwiftData store using the identical schema**.
  - **Pre-sync (M4):** events mirror between watch and phone via WatchConnectivity (`transferUserInfo` — queued, survives the phone being unreachable at the bar).
  - **Post-sync (M5):** CloudKit becomes the shared source of truth; WatchConnectivity remains as the fast path so the phone updates instantly when both devices are present.
  - Both channels can deliver the same event; merges **dedupe by event UUID**, so double delivery is harmless and idempotent by construction.

---

## 8. iCloud sync

Ships as its own milestone, but costs almost nothing because §1's rules were followed from the start:

- Flip the SwiftData `ModelConfiguration` from `cloudKitDatabase: .none` to the private database (`iCloud.com.<team>.tally`) on both iOS and watchOS targets.
- CloudKit **private database only** — user data never touches a shared or public DB, and Apple encrypts it at rest.
- Conflict posture: `DrinkEvent`s are append-only plus explicit deletes (undo), so last-writer-wins is safe. Venues run the dedupe/merge pass from §1 after sync events.
- Settings toggle, on by default when an iCloud account is present; the app remains fully functional signed-out.

---

## 9. App structure

Three tabs: **Tally** (counter + live Session card), **Trends**, **You** (streaks/badges/settings). History — the list of past Sessions, each with an editable drink timeline, venue assignment, note, and pin — lives behind the today count on the Tally tab.

Tech: SwiftUI · SwiftData (App Group + CloudKit-ready schema) · WidgetKit + AppIntents · WatchConnectivity · CoreLocation (`CLMonitor` geofencing) + MapKit · Swift Charts · UserNotifications · HealthKit (read: activity; write: alcoholic beverages). No custom backend, no accounts beyond iCloud.

---

## 10. Privacy & health posture

- All data on-device or in the user's private iCloud database. No analytics, no third-party SDKs, no custom server.
- Location is captured only at the moment of logging. The exception is opt-in Bar Radar (§2), which requests Always permission only when enabled. Tier 1 registers geofences at chosen venues, evaluated by the OS — the app receives entry/exit events only. The discovery tier (on by default once Bar Radar is enabled, with its own toggle to turn off) additionally uses OS visit monitoring, which reports places you linger so the app can match them against bar POIs on-device; non-matches are discarded immediately and never stored. The Bar Radar opt-in flow describes both tiers before requesting the permission upgrade. Neither tier involves a continuous location stream, and disabling Bar Radar drops back to When-In-Use.
- **HealthKit**, both directions optional and off by default: write `numberOfAlcoholicBeverages`; read activity metrics for health insights (§4). HealthKit data is never written to the app's own store or to CloudKit — the insights engine reads each device's local HealthKit store at computation time and persists nothing (HealthKit handles its own cross-device sync). Revoking the permission removes the insight surfaces and nothing else.
- Not a medical device; no health claims. Insights report correlations in the user's own data, never diagnoses or medical advice. Settings links to standard-drink guidelines.

---

## 11. Milestones

1. **M1 — Count:** logging UI, SwiftData store with CloudKit-compatible schema, today view, undo, retro-log.
2. **M2 — Place:** location fix, home setup, POI inference, check-in flow, Sessions (derivation + live card + History + materialize-on-touch with notes/pins).
3. **M3 — Widget:** interactive widgets, shared store, reconciliation flow.
4. **M4 — Watch:** watchOS app, complications, WatchConnectivity mirroring, UUID-dedupe merge.
5. **M5 — Sync:** enable CloudKit on both targets, venue merge pass, settings toggle.
6. **M6 — Trends:** charts tab, stat tiles, Session share cards.
7. **M7 — Play:** points, streaks, badges.
8. **M8 — Nudge:** notification categories, scheduling, quiet hours.
9. **M9 — Radar:** frequented-venue derivation, Always-permission upgrade flow, `CLMonitor` geofences, arrival + dwell notifications with actionable +1, per-venue mute; discovery tier (`CLVisit` visit monitoring, POI matching, hour/frequency gating, suppression list).
10. **M10 — Insights:** HealthKit read permission flow, correlation engine with statistical guardrails, Trends insight cards + morning-after chart, Activity insight notifications, background delivery.

Each milestone ships a usable app; M1 alone is already the core product.

---

## Open questions

- **Drink subtypes / standard-drink sizes?** v1 treats every alcoholic drink as 1 unit. Tracking beer/wine/spirits or ABV-adjusted units adds a second tap — against the one-button ethos. Could be an optional long-press picker later.
- **Watch-first pacing haptics?** Beyond mirrored notifications, the watch could fire its own gentle haptic for pacing nudges even when the phone is present. Deferred until M8.
- **Sleep & resting heart rate insights?** Natural extensions of the M10 engine (drinking vs sleep duration/quality, morning resting HR), but they read as more medical than activity minutes and deserve their own framing pass. Revisit after M10 ships.
- **Android?** Not in scope; native iOS assumed.
