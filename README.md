# Tally

A one-tap drink counter for iPhone and Apple Watch. Log a drink the moment it lands in your hand; Tally handles the rest — where you were, how the night unfolded, and what the trend looks like over weeks.

Built native for **iOS 26 / watchOS 26** in SwiftUI (Liquid Glass), Swift 6 language mode throughout.

## Features

- **One-tap logging** — a big +1 for alcoholic drinks, a second button for non-alcoholic ones, undo semantics, and long-press retro-logging for the drink you forgot.
- **Sessions & venues** — each drink grabs a one-shot location fix; Tally infers venues via MapKit POIs and geofencing ("Bar Radar" can notice you've settled in somewhere and offer a check-in). Venues can be muted; home gets special handling.
- **Trends** — weekly and monthly visualizations, pace within a session, and optional HealthKit-backed insights.
- **Widgets & complications** — home-screen counter, glance, and sparkline widgets; a full watch app with complications so logging never requires the phone.
- **Local-first, iCloud-ready** — the data layer is CloudKit-compatible from day one, so sync is a switch-flip rather than a migration.

## Architecture

```
TallyKit/            Swift package: the entire domain layer
  Store/             event store (CloudKit-compatible identity rules)
  ...                scoring engine, session deriver
tally/               iOS app, organized by feature
  Tally/ Trends/ You/ Place/ History/ ShareCard/ Onboarding/ Settings/
TallyWidget/         WidgetKit extension
TallyWatch/          watchOS app
TallyWatchComplications/
tallyUITests/        XCUITest suites per feature
```

Domain logic lives in `TallyKit` with its own unit test suite (`swift test` from `TallyKit/`); the apps are thin SwiftUI layers over it. `SPEC.md` is the product spec the implementation tracks; `PLAN.md` is the running build plan.

## Building

Open `tally.xcodeproj` in Xcode 27+. Schemes: `tally` (iOS), `TallyWatch`, `TallyWidget`, `TallyWatchComplications`.

```sh
# domain-layer tests
cd TallyKit && swift test
```

## Privacy posture

Everything stays on device (or in your private iCloud database once sync is enabled). Location is captured as one-shot fixes only, never continuous tracking; denying location permission degrades gracefully.

## Built with Claude

Nearly every commit in this repo is co-authored with Claude Code — the history is a real record of a spec-first, agent-assisted build, including parallel work in isolated worktrees.

## License

[MIT](LICENSE)
