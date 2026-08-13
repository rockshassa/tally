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

### Bar Radar — frequented-venue detection

Once the app has accumulated venue history, it proactively notices you're at a place you drink at and reminds you to track. This is the one feature that needs **Always** location — everything else runs on When-In-Use — so it's a separate, clearly-explained opt-in ("Bar Radar") that triggers the permission upgrade only when enabled.

- **Frequented** = a venue with ≥ 3 Sessions in the trailing 90 days, derived from the event log (never stored, per §1). Home and muted venues are excluded.
- The app registers OS geofences (`CLMonitor` circular conditions) for the top frequented venues by recency, staying under the system's ~20-region cap. Geofence evaluation is done by the OS on-device — the app receives entry/exit events only, never a location stream.
- **On entry:** auto check-in to the venue (it's known — no confirmation sheet needed) and fire a local notification: *"Looks like you're at **The Anchor** — start a Session?"* with actions:
  - **+1 drink** — logs directly from the notification, opening the Session auto-tagged to the venue, without launching the app.
  - **Not drinking tonight** — suppresses all further prompts for this visit.
- **Dwell follow-up:** at entry, schedule a second notification for +45 min (configurable): *"Still at The Anchor — start a Session?"* It's cancelled if any drink gets logged or the exit event fires first. **One follow-up maximum per visit** — after that, silence.
- Exit followed by re-entry within 2 h counts as the same visit (stepping outside shouldn't re-trigger the arrival prompt).
- Controls: global Bar Radar toggle, per-venue mute (also offered as an action on the arrival notification after repeated dismissals), and it never applies to Home.

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

Tone throughout: neutral-to-encouraging, never shaming. Upward-trend alerts state facts ("up 20% vs last month") without judgment. Quiet hours apply to every category except the two Bar Radar ones — bar hours *are* quiet hours, and those prompts are the feature.

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

Tech: SwiftUI · SwiftData (App Group + CloudKit-ready schema) · WidgetKit + AppIntents · WatchConnectivity · CoreLocation (`CLMonitor` geofencing) + MapKit · Swift Charts · UserNotifications. No custom backend, no accounts beyond iCloud.

---

## 10. Privacy & health posture

- All data on-device or in the user's private iCloud database. No analytics, no third-party SDKs, no custom server.
- Location is captured only at the moment of logging. The one exception is opt-in Bar Radar (§2): Always permission is requested only when that feature is enabled, geofences are evaluated by the OS on-device, and the app receives entry/exit events at chosen venues — never a continuous location stream. Disabling Bar Radar drops back to When-In-Use.
- Optional **HealthKit** write: `numberOfAlcoholicBeverages` (off by default).
- Not a medical device; no health claims. Settings links to standard-drink guidelines.

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
9. **M9 — Radar:** frequented-venue derivation, Always-permission upgrade flow, `CLMonitor` geofences, arrival + dwell notifications with actionable +1, per-venue mute.

Each milestone ships a usable app; M1 alone is already the core product.

---

## Open questions

- **Drink subtypes / standard-drink sizes?** v1 treats every alcoholic drink as 1 unit. Tracking beer/wine/spirits or ABV-adjusted units adds a second tap — against the one-button ethos. Could be an optional long-press picker later.
- **Watch-first pacing haptics?** Beyond mirrored notifications, the watch could fire its own gentle haptic for pacing nudges even when the phone is present. Deferred until M8.
- **Android?** Not in scope; native iOS assumed.
