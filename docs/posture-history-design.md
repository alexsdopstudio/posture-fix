# Posture history: design

Goal: record posture like a training log, learn the user's **habitual** posture (not the ideal one) and move it toward the calibrated neutral step by step, with progressive targets instead of constant alarms.

## Decisions (2026-11-01)

| Topic | Decision |
|---|---|
| Storage | Local JSON Lines files behind a `PostureHistoryStore` protocol (no Xcode on the dev Mac, so no SwiftData yet). Move to SwiftData + CloudKit when Xcode is available. |
| Frontmost app | Recorded only if the user opts in. **Off by default.** Bundle identifier only, stays on the Mac. |
| Targets | **Progressive**: start just beyond the habitual posture, tighten ~1°/week when the target is met, hold or relax on regressions. The fixed spec threshold stays as the upper limit. |
| Retention | Per-minute records for 90 days, then one daily summary per day, forever. |

## Phases

1. **Collection and storage** (this phase): per-minute aggregates, events, retention.
2. **Profile and charts**: habitual posture (median + spread over 14 days), worst hours, fatigue curve by sitting time, lateral habit, response to nudges. Swift Charts in a "Profilo" window, a day timeline in the menu panel.
3. **Progressive targets and insights**: personal nudge threshold, at most one actionable insight per day, weekly summary, link to `AdaptivePrescriptionEngine`.

## Data model (phase 1)

`PostureMinuteRecord`, one per wall-clock minute with at least 5 s of real AirPods data (simulated samples are never recorded):

* tracked and moving (motion-gated) seconds;
* pitch relative to the neutral over judged samples: mean, median, p10, p90;
* mean roll (sign = side);
* seconds per category: in axis, between, tech neck, turtle, left lean, right lean;
* seconds per engine state: neutral, drifting, magnetic nudge, recovery;
* sitting-session length at the end of the minute (a break is 2 min without being seated);
* calibration id (records from different calibrations are never mixed blindly);
* dominant frontmost app (only when opted in).

`PostureEventRecord`: nudge started, recovered (with latency from nudge start), relapsed (drifting again, with time since the last recovery), calibrated (with whether the webcam was used and which cues were unmet).

Files: `~/Library/Application Support/Flow/History/YYYY-MM-DD/{minutes,events}.jsonl` and `summaries.jsonl` for days older than the retention window. About 1,440 lines (~300 KB) per day.
