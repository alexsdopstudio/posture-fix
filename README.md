# Posture Fix · Flow v3.0 "Insanely Great Zero-UI Edition"

Flow is a privacy-first posture and training companion that runs on head kinematics alone.
There is no webcam and no cloud inference. The input is AirPods motion (`CMHeadphoneMotionManager`), plus an optional iPhone in the trouser pocket at the gym.

It works in two places with one number:

| Context | What Flow does | The number |
|---|---|---|
| **Desk** (macOS menu bar) | Detects tech neck, turtle neck and lateral lean, then nudges you back with a peripheral vignette and a 432 Hz spatial tone behind your head | Daily **Flow Score %** |
| **Gym** (Pocket Mode) | Auto-starts the set, recovers rep 1 retroactively, routes each set to the right pipeline, scores technique | Set **Flow Score 0-100** |

The **Desk <-> Gym bridge** closes the loop: posture debt from the desk changes the next workout.

> Zero-UI means no buttons in the steady state: calibration is automatic, sets start themselves, and the only thing on screen is one number.

---

## Repository layout

```
posture-fix/
├── Packages/BiomechanicsCore/         Shared Swift package (iOS 17+, macOS 14+, Swift 5.10)
│   ├── Sources/BiomechanicsCore/
│   │   ├── Math/                      Quaternion algebra, Vector3, statistics
│   │   ├── DSP/                       RBJ biquads, zero-phase band-pass
│   │   ├── Models/FlowModels.swift    SwiftData + CloudKit models
│   │   ├── Sensors/                   Ring buffer, auto-start, calibration, AirPods service
│   │   └── Engines/                   Desk engine, Pipeline A/B, router, Flow Score, prescriptions
│   └── Tests/BiomechanicsCoreTests/   41 deterministic tests on synthetic signals
├── Apps/FlowMac/                      macOS 14+ menu bar app (executable package)
│   └── Sources/FlowMac/
├── Makefile                           test / build / run shortcuts
├── CLAUDE.md                          Guide for coding agents
└── README.md
```

## Quick start

```bash
make test     # swift test --package-path Packages/BiomechanicsCore (+ CLT flags if needed)
make build    # swift build --package-path Apps/FlowMac
make run      # launches the menu bar app
```

With Xcode installed you can also open either `Package.swift` in Xcode, or run
`swift test --package-path Packages/BiomechanicsCore` directly.

### Command Line Tools-only Macs

Apple's Command Line Tools (without Xcode) lack two things this project uses:

1. **The SwiftData macro plugin.** `Packages/BiomechanicsCore/Package.swift` resolves the active developer directory (`DEVELOPER_DIR`, then `xcode-select`). On CLT it defines `FLOW_SWIFTDATA_MACROS_UNAVAILABLE`, and `FlowModels.swift` compiles plain classes with the identical API in place of the `@Model` classes. Any Xcode toolchain compiles the real `@Model` variants.
2. **A default search path for the Testing framework.** The manifest adds the linker rpaths. SwiftPM still only runs swift-testing when `-Xswiftc -F<frameworks>` is on the command line, which is why `make test` passes that flag when CLT is active.

---

## Architecture

### 1. Models (`Models/FlowModels.swift`)

SwiftData `@Model` classes that follow the CloudKit rules: every stored property has a default, relationships are optional, there are no unique constraints, and enums are persisted as raw strings with typed accessors.

* `PipelineCategory`: `.kinematicZUPT`, `.cranialCrossCoupling`
* `LimbSide`: `.bilateral`, `.left`, `.right`
* `DailyPostureSummary`: `date`, `totalTrackedMinutes`, `techNeckAndTurtleMinutes`, `leftLeanMinutes`, `rightLeanMinutes`, `longestStaticStretchMinutes` (input of the static-rigidity rule), `dynamicNeutralPitchBaseline` (85th percentile), `dailyDeskFlowScore` (0-100), `postureRecoveryStreak`
* `WorkoutSession`: `id`, `date`, `appliedDeskAdaptations: [String]`, `sessionFlowScore`, `sets` (`@Relationship(deleteRule: .cascade)`)
* `ExerciseSet`: `id`, `exerciseName`, `autoDetectedPipeline`, `side`, `loadKg`, `totalReps`, `cleanReps`, `flowScore` (primary UI metric), plus optional telemetry: `meanConcentricVelocity`, `averageEccentricSeconds`, `thighRomDegrees`, `bilateralSymmetryRatio`, `maxPitchDeviation`, `maxRollDeviation`

### 2. Retroactive ring buffer (`Sensors/RetroactiveRingBuffer.swift`)

* `IMUSample`: `timestamp`, `quaternion`, `userAcceleration` (g), `gravity` (unit g), `rotationRate` (rad/s), `pocketThighPitch` (degrees, optional).
* `RetroactiveRingBuffer`: lock-protected circular buffer, 5.0 s at 50 Hz = 250 samples. It always holds the last 5 s during gym rest.
* `RepAutoStartDetector`: a single movement is ignored (re-racking, walking). The second movement onset *in the same direction* within 4 s fires `AutoStartTrigger`, which carries the timestamp of rep 1 and a 1 s pre-roll. Rep 1 is then pulled out of the buffer with `samples(from:through:)` or `retroactiveCapture(triggeredAt:lookback:)`.

### 3. Head motion and Zero-Touch calibration (`Sensors/`)

* `HeadphoneMotionService` (`@MainActor @Observable`) streams `CMHeadphoneMotionManager` at 50 Hz and reports connect/disconnect. When no real sample has arrived for 1 s (AirPods not worn, access denied, or no hardware), a deterministic `SeatedHeadSimulator` takes over, so the app and tests always have input.
* Gimbal-lock free algebra: every attitude is `current.multiply(byInverseOf: dynamicReferenceAttitude)` (Hamilton product with the inverse reference), then converted to pitch θ (X), roll ϕ (Y), yaw ψ (Z) in degrees.
* `ZeroTouchAutoCalibrator`:
  * **Seated detection**: the standard deviation of `|userAcceleration|` stays below 0.02 g for 10 s.
  * Every sit-down captures a new dynamic reference attitude.
  * While seated, relative pitch is sampled every 0.2 s into a 5 min window. The **upper 85th percentile** becomes the neutral baseline. Slouching pulls pitch down, so the upper percentile follows the user's own upright posture without any calibration button.

### 4. Desk posture engine (`Engines/DeskPostureEngine.swift`)

Privacy-first: head kinematics only, no camera.

| Stage | Rule |
|---|---|
| Smoothing | EMA, `alpha = 0.05`, on pitch and roll |
| Motion gate | freeze all timers when `|userAcceleration| > 0.08 g` or `|rotationRate| > 0.5 rad/s` |
| Tech neck | smoothed pitch more than 10° below the P85 baseline |
| **Kinematic Turtle Signature** | forward glide (1 s mean `userAcceleration.y > +0.015 g`, latched) **and** C1-C2 micro-extension (+1° to +8° above baseline) **and** postural sway variance below 60% of the learned reference (a 40% reduction) |
| Lateral lean | smoothed roll beyond ±8° (positive roll = right) |
| In axis | no deviation, `|Δpitch| < 5°`, `|roll| < 4°` |

State machine:

```
neutral ──15 s deviating──▶ drifting ──45 s deviating──▶ magneticNudge
   ▲                           │                              │
   └──── 1.5 s in axis ────────┘                    1.5 s in axis, streak +1
   └──── after 2 s ─────────── dopamineRecovery ◀─────────────┘
```

`DeskPostureMetrics` accumulates tracked, tech neck + turtle, left lean, right lean and longest static stretch seconds. The daily Flow Score is the share of tracked time without a deviation.

### 5. Gym: parallel pipeline router (`Engines/ParallelPipelineRouter.swift`)

Both pipelines run concurrently (`async let`) over the retroactive buffer.

**Pipeline A: `KinematicZUPTEngine`** (squat, deadlift, lunge)

1. Earth-frame vertical acceleration: `a_vert(t) = -(ax·gx + ay·gy + az·gz) · 9.81`.
2. **ZUPT windows**: runs of at least 150 ms where `a_vert` is flat (peak-to-peak < 0.3 m/s² over a 150 ms window) *and* near zero (< 0.5 m/s²), i.e. the lockout and the pause in the hole. Runs are dilated by half a window to undo the centred-window erosion. Velocity is forced to 0 inside.
3. **Linear Retroactive Dedrifting** between two anchors:
   `v_corrected(t) = v_raw(t) - (v_raw(T_end) / (T_end - T_start)) · (t - T_start)`,
   which cancels any constant accelerometer bias exactly.
4. Each anchored segment is split into eccentric/concentric phases from the integrated position, including touch-and-go reps split at the turning point. Outputs: MCV (m/s), eccentric duration, vertical excursion, femur ROM from `pocketThighPitch`.

**Pipeline B: `CranialCrossCouplingEngine`** (curl, lateral raise, bench: the head stays still)

1. Zero-phase band-pass of vertical head acceleration, 0.35-2.2 Hz (2nd-order RBJ high-pass + low-pass, forward-backward, reflection padded).
2. Each positive lobe whose peak lies in the **0.015-0.06 g thoraco-cranial tension envelope** is one rep. Larger peaks are whole-body movement and are rejected, together with the filter-ringing side lobes next to them.

**Auto-classification in 1.5 s.** Motion onset is found after removing the bias measured in the first stillness window. Over the next 1.5 s the router double-integrates `a_vert`:

* excursion > 12 cm **or** femur rotation > 25° → Pipeline A
* excursion < 8 cm **and** the envelope is in the tension band for ≥ 50% of the window → Pipeline B
* 8-12 cm grey zone → B if periodic, else A, with confidence 0.5

**Flow Score Engine** (`Engines/FlowScoreEngine.swift`), one integer 0-100:

* **Purity 50%**: per rep `100 - 4·max(0, Δθ - 12°) - 5·max(0, |Δϕ| - 8°)`. A rep is *clean* when it crosses neither threshold.
* **Symmetry L/R 30%**: `min/max` of the two sides' mean rep duration (Pace Matching), averaged with the MCV ratio when both sides have one. Bilateral work scores 100.
* **Tempo Rhythm 20%**: `100 · max(0, 1 - CV(rep durations) / 0.3)`.

`SetAnalysis.makeExerciseSet()` turns the result into a persistable `ExerciseSet`.

### 6. Desk <-> Gym bridge (`Engines/AdaptivePrescriptionEngine.swift`)

| Desk debt | Prescription |
|---|---|
| `techNeckAndTurtleMinutes > 90` | 2 sets of **Face Pulls / Band Pull-Aparts** with a 2 s hold, pre-workout |
| `leftLeanMinutes` or `rightLeanMinutes > 60` | **Suitcase Carry / Side Plank** on the *opposite* side of the dominant lean. Every unilateral exercise gets **Weak-Side First** (starting side = opposite side) and **Pace Matching** |
| static rigidity > 3 h (`longestStaticStretchMinutes > 180`) | **40 s Couch Stretch** in the first two rest intervals |

Applied adaptations are tagged on `WorkoutSession.appliedDeskAdaptations`, e.g. `["techNeckPullAparts", "lateralLeanCarry.right", "weakSideFirstPaceMatching.right", "staticRigidityCouchStretch"]`.

---

## FlowMac (macOS menu bar)

* **`FlowMacApp.swift`**: `MenuBarExtra` (`.window` style) with `NSApplication.shared.setActivationPolicy(.accessory)`, so there is no Dock icon. The menu bar shows the Flow Score %. The panel shows the score, the live state, the recovery streak, the AirPods status (live / not worn, simulation on / unavailable), the calibration status, and the demo toggle **🧪 Simula Tech Neck (>45s)** / **✨ Raddrizza Postura**.
* **`FlowController.swift`**: glues `HeadphoneMotionService` → `DeskPostureEngine` → nudges, and resets the daily metrics at midnight. The demo button injects a −22° flexion and a +7° right roll and fast-forwards past 45 s, so the overlay and the audio start immediately. "Raddrizza" removes the injection, and the engine recovers by itself after 1.5 s in axis (chime included).
* **`PeripheralOverlayWindow.swift`**: a `@MainActor` controller that creates one `.borderless`, `.clear`, `.screenSaver`-level, `ignoresMouseEvents = true` window per `NSScreen.screens` entry (rebuilt when screens change). A SwiftUI view draws a progressive peripheral vignette (intensity ramps over 10 s of nudge). The clear centre shifts away from the lean and the leaning side gets darker.
* **`SpatialMagneticAudioEngine.swift`**: `AVAudioEngine` + `AVAudioSourceNode` generating a pure 432 Hz sine in real time (20 ms amplitude glide, no clicks), routed in mono into an `AVAudioEnvironmentNode` with `.HRTFHQ`. The source sits 1.5 m behind the nape (`z = 1.5`) and moves on X opposite to the head's roll. The **Dopamine Chime** is `NSSound(named: "Glass")` on recovery.
* `Info.plist` (with `NSMotionUsageDescription` and `LSUIElement`) is embedded in the executable via `-sectcreate __TEXT __info_plist`, so CoreMotion can request access when the app runs straight from `swift run`.

## Tests

`Packages/BiomechanicsCore/Tests/BiomechanicsCoreTests` uses swift-testing. Every signal is synthetic and seeded (SplitMix64 + Box-Muller), so runs are fully deterministic.

| Suite | Covers |
|---|---|
| `RetroactiveRingBuffer` | 250-sample capacity, overflow order, concurrent writers, **rep 1 recovered when rep 2 fires Auto-Start**, single movements ignored |
| `Pipeline A` | `a_vert` projection; naive integration drifts (> 0.35 m/s) while **ZUPT + linear dedrifting** ends at exactly 0; 7 ZUPT windows ≥ 150 ms; MCV within 5% of 0.625 m/s under a 0.05 m/s² bias + noise; eccentric time, excursion, femur ROM; touch-and-go reps |
| `Pipeline B and auto-routing` | 10/10 curl reps counted; squats rejected by B; **squats → A, curls → B**; femur rotation forces A; buffer → router; async == sync |
| `Flow Score` | weights, cheat penalties, tempo CV, empty set |
| `DeskPostureEngine` | full **neutral → drifting → magneticNudge → dopamineRecovery → neutral** cycle; drifting recovery; motion gate (accel + gyro); EMA step; **turtle signature** and its negative case; lateral lean; demo fast-forward; summary mapping |
| `Quaternion + Zero-Touch` | Euler round-trip; relative attitude near gimbal lock; 10 s seated detection + P85 baseline; standing up |
| `AdaptivePrescriptionEngine` | each rule in isolation, dominant lean, combined tags, session score |

## Known limits

* The `@Model` branch of `FlowModels.swift` compiles only on a toolchain with the SwiftData macro plugin (any Xcode). On Command Line Tools the plain-class fallback with the same API is used.
* Gym Pocket Mode lives in `BiomechanicsCore` (engines, models, tests). The iOS/watchOS front-end that feeds it is not part of this repository yet.
* Detection thresholds come from the v3.0 spec and are validated on synthetic signals only, not yet on recorded AirPods data.
