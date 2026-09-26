# Fibrinolytic suppression: first drink to baseline

Status: proposed changes, September 19, 2026. This document describes the design and implementation work; it does not change the app.

## Intended experience

Show the entire modeled progression by default: **first drink → rise → peak → decline → 0 / baseline**. Opening the chart the next morning should still show where the progression began and how much remains. The user should not need to pan or select a range to find either endpoint.

Keep a visible **Now** marker within that complete timeline. Time passing moves the marker along the curve instead of sliding the beginning of the curve offscreen. Logging another drink can extend the timeline and change its shape.

## What needs to change

The current implementation has several limits:

| Current behavior | Proposed behavior |
| --- | --- |
| App plots `now − 6h` through `now + 18h`. | Fit the full drinking-and-recovery episode. |
| Widget plots `now − 3h` through `now + 12h`. | Use the same episode boundaries in its compact curve. |
| Summary looks for a future peak; earlier peaks disappear from the story. | Keep the episode's overall peak visible after it passes. |
| Baseline lookup returns `nil` when the current value is already at baseline, including the initial absorption delay. | Find the return after the episode's final rise, even immediately after logging its first drink. |
| The card can disappear as soon as a long recovery finishes. | Retain the completed curve briefly so the user can see it reach baseline. |
| Clock-only axis labels and a “tomorrow” shortcut assume a short range. | Use day-aware labels that work across multiple days. |

These findings come from `SuppressionCurveCard.swift`, `FibrinolysisModel.swift`, and the widget's `SuppressionCurveView.swift`. They concern the existing software model; this proposal does not reassess its scientific parameters.

## Define what “back to 0” means

The model uses exponential decay, so its raw index does not reach exact zero in a finite useful chart range. Its existing `baselineThreshold` is **3**, and current UI logic treats values at or below that threshold as baseline.

For the chart, propose a baseline-relative display value:

```text
displayed suppression = max(0, raw model index − baselineThreshold)
```

This gives the curve a continuous, honest endpoint at zero without changing the underlying model or inventing a recovery cutoff. Label the vertical scale **Modeled suppression above baseline**. This is a change from the current raw-index axis: chart numbers must consistently use the new display value, including the Now dot, peak, and inspection readout. Never present them as percentages. With the current configuration, the raw ceiling of 100 corresponds to 97 above baseline.

Use **0 · modeled baseline** at the endpoint. Explain in the chart's information text: “Zero on this chart means the model is within its baseline range. It is not a measured biological value.” Keep the existing model, classification, and suppression-hours calculations on the raw index.

The opening segment also rests at zero during the model's initial delay. Copy should say **Rise ahead** when a future rise exists, so this initial flat segment cannot be mistaken for completed recovery. Forecast copy should include **Based on logged drinks; assumes no additional drinks**.

## Choose the full episode

An episode is a drinking-and-recovery interval, not necessarily one of the app's existing sessions. Drinks on consecutive days belong to one episode if the previous episode has not returned to modeled baseline.

1. Use alcoholic events with timestamps at or before the current clock. Non-alcoholic and future-dated entries do not start or extend the episode.
2. Start at the first drink after the preceding completed return to baseline, or the first recorded alcoholic drink if there is no earlier episode.
3. Add any drink logged before that episode's projected return. Recompute the curve and return time from the accumulated events. A drink at or after a completed return starts a new episode.
4. Find completion only after all included drinks have passed their pulse peaks and the combined raw curve has fallen to `baselineThreshold` or below. A temporary low point before a pending rise is not completion.
5. Display the active episode, or the most recently completed episode during the retention period below.

Retain earlier contributions needed to calculate the episode accurately, including compression weights. An episode boundary is a display boundary, not permission to reset the model's remaining tails to zero. Determine boundaries using that retained context.

Replace the card's fixed 66-hour event cutoff with episode-aware history selection. A prolonged episode must not silently lose its first drinks as they age past that cutoff. If history is incomplete, label the start **Available history** rather than claiming it is the first drink.

## Layout and interaction

Use a modestly taller chart in the Tally card, targeting **140–160 points** instead of 84, subject to small-screen layout verification. Keep the logging buttons accessible. Offer an expanded chart for more room and inspection; the compact card must already show the complete range.

Above the chart, show **Modeled fibrinolytic suppression** and a short state: **Rise ahead**, **Rising**, **Easing**, or **At modeled baseline**. Derive rising/easing from the local direction of the curve, separately from its overall peak. A multi-drink episode can have several rises and local peaks.

Plot these elements:

- **First drink:** a start marker and logged date/time. Small ticks along the bottom mark subsequent drinks; combine overlapping ticks into a count.
- **Peak:** mark the highest modeled value across the entire episode, whether past or future. For a capped plateau, label the first occurrence and describe the interval in the expanded view.
- **Now:** a clearly labeled vertical rule and point while the episode is active. Use a solid curve for elapsed time and a dashed curve for future time. Both portions remain modeled.
- **0 / baseline:** a labeled endpoint with approximate date/time. Extend the plot a little beyond it to make the flat zero tail visible.

Use amber and neutral ink, following the existing product rules. Avoid coloring the whole historical curve neutral just because the current value is at baseline; its earlier progression should remain legible.

Anchor the horizontal range at the first drink with small visual padding, and end just beyond modeled return. Use proportional padding, bounded to roughly 15–60 minutes per side. Do not include long empty stretches solely to keep Now onscreen after completion. On a completed curve, replace the Now rule with **Returned to modeled baseline ~[day/time]**.

Use approximately 4–6 readable time labels, adding calendar day labels across midnight and dates for longer ranges. Format “today,” “tomorrow,” or a weekday/date from actual calendar relationships, not elapsed-hour thresholds. Respect locale, time zone, and daylight-saving changes. Keep forecast times approximate and rounded to the hour; logged drink times can retain their recorded precision.

Keep the vertical scale anchored at zero and sized to the entire episode peak with modest headroom. It should not rescale just because the clock advances. Label it clearly so different episode heights are not mistaken for identical magnitudes.

Below the chart, show three compact facts: **First drink**, **Peak / Peaked**, and **Baseline / Returned**. These remain readable when chart annotations collide. In the expanded view, tapping or dragging reveals the modeled value and time at the selected point. Provide accessible alternatives to dragging and a VoiceOver summary covering start, peak, current state, and return.

## Completion and updates

Keep the latest completed episode on the Tally screen until the later of **24 hours after its last drink** or **24 hours after its modeled return**. A new episode replaces it immediately. This intentionally extends the existing visibility rule so the completed progression can be seen.

After retention expires, hide the card. Keep completed timelines available from session detail while recovery context is enabled. If several sessions belong to one recovery episode, each detail screen opens that same complete episode and highlights its own drinks.

Recompute after insertion, deletion, undo, and edits to drink timestamp or type, including changes that leave the event count unchanged. Refresh Now when the app becomes active and while the chart is visible. Event changes may merge or split episodes; the resulting boundaries must follow the updated log.

Recovery context off continues to remove all recovery surfaces.

## Implementation outline

Introduce a pure `SuppressionTimeline` builder in `TallyKit` shared by the app and widget. It should return episode boundaries, contributing drink markers, raw and display samples, overall peak or plateau, current state, baseline return, completion state, and history completeness. Views handle localized text and drawing.

Do not use `baselineReturn(after: now)` alone: it returns `nil` during the opening delay, and its default search horizon is 48 hours. Search from the final included drink's peak, extending the horizon until the downward baseline crossing is bracketed, then refine it. A defensive computation limit must produce an explicit unavailable endpoint, never a fabricated zero or a claim that the full timeline is shown.

The existing `curve` sampler may omit an exact end date when the range is not divisible by its step. Explicitly include the first drink, Now when in range, pulse transitions, peak boundaries, and the baseline crossing. Sampling may become coarser for long episodes, but preserve those anchors. Keep any decimation for rendering separate from milestone calculations.

Precompute each drink's compression weight rather than recalculating it for every plotted sample. Cache episode geometry between clock ticks and invalidate it when relevant event content changes. Avoid passing the entire log through the existing quadratic pulse calculation every minute. History pruning must have a documented numerical tolerance and must not remove an episode's displayed origin.

| Area | Planned change |
| --- | --- |
| `TallyKit/Sources/TallyKit/Recovery/` | Add timeline derivation and tests while preserving raw model behavior. |
| `tally/Features/Tally/SuppressionCurveCard.swift` | Replace rolling window and summary derivation; render milestones, display values, and expanded interaction. |
| `tally/Features/Tally/TallyScreen.swift` | Verify increased card height, sheet presentation, and refresh behavior. |
| session detail in `tally/Features/History/` | Open completed episodes and highlight the selected session's drinks. |
| `TallyWidget/SuppressionCurveView.swift` | Consume the shared timeline; show full shape with Now and a compact baseline caption. |
| `TallyWidget/TallyWidgetEntry.swift` | Fetch enough history to find the episode start; the current seven-day fetch cannot guarantee this for prolonged episodes. Schedule endpoint refreshes where WidgetKit permits. |
| `SPEC.md` and recovery explainer | Document the baseline-relative scale, episode definition, and completed-card retention. |

Deliver the shared timeline and full-range app card first, then expanded/history access and widget parity. All three are part of the proposed outcome. No new notifications, model calibration, or data schema changes are required by this design.

## Acceptance criteria

- Immediately after the first drink, the chart shows the opening delay, future rise, peak, and complete return to zero, with a projected return time.
- Opening the app the next morning still shows the same first drink and any peak already passed.
- An episode longer than 24, 48, or 66 hours is shown completely; continuous drinking across sessions does not truncate it.
- Another drink before return extends the same episode; a drink after return starts a new one. Temporary baseline dips with a pending rise do not end an episode.
- Zero on the display corresponds to the existing model threshold. Raw model output and existing suppression-hours results remain unchanged.
- The end sample is present, the curve visibly rests on zero, and endpoint text agrees with that crossing.
- Completion remains visible for the specified retention period and is available later from session detail.
- Undo, deletion, timestamp/type edits, and future-dated events produce the correct timeline. Empty and non-alcoholic-only logs show no chart.
- Tests cover multiple peaks, capped plateaus, incomplete history, and unavailable endpoint handling, as well as single-drink and multi-day episodes.
- Visual verification covers small iPhones, large Dynamic Type, VoiceOver, 12/24-hour clocks, midnight, and daylight-saving transitions. Widget and app agree on episode boundaries and endpoint for the same events and clock.
