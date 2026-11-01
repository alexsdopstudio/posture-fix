# Posture Fix · Flow v3.0 "Insanely Great Zero-UI Edition"

Flow is a privacy-first posture and training companion that runs on head kinematics.
There is no cloud inference. The input is AirPods motion (`CMHeadphoneMotionManager`), plus an optional iPhone in the trouser pocket at the gym. The webcam is used **only during the few seconds of calibration** (on by default, can be turned off), analysed on-device with Vision and never stored. Posture tracking during the day is AirPods only.

It works in two places with one number:

| Context | What Flow does | The number |
|---|---|---|
| **Desk** (macOS menu bar) | Detects tech neck, turtle neck and lateral lean, nudges you back with a 432 Hz spatial tone behind your head, and records your posture history | Daily **Flow Score %** |
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
│   │   ├── Engines/                   Desk engine, Pipeline A/B, router, Flow Score, prescriptions, webcam cues
│   │   └── History/                   Per-minute posture records, events, JSON Lines store
│   └── Tests/BiomechanicsCoreTests/   60 deterministic tests on synthetic signals
├── Apps/FlowMac/                      macOS 14+ menu bar app (executable package)
│   └── Sources/FlowMac/
├── docs/posture-history-design.md     Posture history design and decisions
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

### 3. Head motion and calibration (`Sensors/`)

* `HeadphoneMotionService` (`@MainActor @Observable`) streams `CMHeadphoneMotionManager` at 50 Hz and reports connect/disconnect. When no real sample has arrived for 1 s (AirPods not worn, access denied, or no hardware), a deterministic `SeatedHeadSimulator` takes over, so the app and tests always have input.
* Gimbal-lock free algebra: every attitude is `current.multiply(byInverseOf: dynamicReferenceAttitude)` (Hamilton product with the inverse reference), then converted to pitch θ (X), roll ϕ (Y), yaw ψ (Z) in degrees.
* `ZeroTouchAutoCalibrator` supports two ways of setting the neutral:
  * **Guided calibration** (the one FlowMac uses): when the AirPods are put on, on demand, or when the user sits still for 10 s without a neutral, the user holds an upright head steady for **3 s**. Progress fills while the head stays within 2° of where the hold started (and rotates slower than 0.2 rad/s) and restarts from zero when it moves. An external gate (the webcam) can pause the hold until the posture is right. The held attitude becomes the reference **and** the neutral, and stays the neutral (no P85 drift). Because everything is relative to it, AirPods worn slightly rotated in the ear do not make the head look crooked. Without a steady hold within 20 s it gives up and reopens at the next sit-down.
  * **Zero-Touch automatic capture** (spec behaviour, `allowsAutomaticCapture = true`, the library default): seated detection (std of `|userAcceleration|` < 0.02 g for 10 s) captures the reference; brief movements keep it, only 60 s away recaptures it. While seated, relative pitch is sampled every 0.2 s into a 5 min window and its **upper 85th percentile** becomes the neutral baseline. FlowMac turns this off: an automatic capture can silently adopt a slouched posture as "correct".
  * The simulated head (no AirPods) adopts its first sample as neutral, so the demo controls work.

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

### 6. Webcam-assisted calibration (`Engines/CameraPostureAssessment.swift`)

FlowMac reduces each webcam frame (Vision face landmarks + body pose, ~10 per second) to a `CameraPostureObservation`: eye-line tilt, face yaw, face centre, eye height, face width, shoulder tilt and span. `CameraPostureAssessment` turns it into cues:

| Cue | Rule | Type |
|---|---|---|
| Face visible | a face is detected | blocking |
| Head level | eye-line tilt ≤ 3° | blocking |
| Facing the screen | face yaw ≤ 10° | blocking |
| Centred | face centre within 0.2 of the frame centre | blocking |
| Shoulders level | shoulder tilt ≤ 4° (when visible) | blocking |
| Distance | face width 0.12-0.27 of the frame (~85-40 cm on a laptop camera) | advisory |
| Chin back | face/shoulder width ≤ 0.55 (head pushed forward raises it) | advisory |
| Screen height | eyes ≤ 0.72 of the frame height | advisory |

The guided hold only fills while every blocking cue holds, so the AirPods reference is captured on a head the camera confirms is level and facing the screen. The webcam never blocks for more than 10 s (advice stays visible), and with no camera, no permission or no frame within 4 s the calibration continues with AirPods only. Advisory cues are estimates from a frontal camera and never block.

### 7. Posture history (`History/`)

See [docs/posture-history-design.md](docs/posture-history-design.md) for the full design and decisions. Phase 1 is implemented:

* `PostureMinuteAggregator` folds the 50 Hz stream into one `PostureMinuteRecord` per wall-clock minute: tracked and moving seconds, pitch vs neutral (mean, median, p10, p90 over judged samples), mean roll, seconds per category and per engine state, sitting-session length (a break is 2 min not seated), calibration id, and the dominant frontmost app when the user opts in (off by default).
* `PostureEventTracker` records nudges, recoveries (with latency) and relapses (with how long the recovery lasted); calibrations are recorded with whether the webcam took part.
* `FilePostureHistoryStore` writes JSON Lines under `~/Library/Application Support/Flow/History/YYYY-MM-DD/`. Torn lines are skipped on read. After 90 days a day is compacted into one `PostureDaySummary` in `summaries.jsonl`.
* Only real, calibrated AirPods data is recorded: never the simulated head, never samples before or during a calibration.

### 8. Desk <-> Gym bridge (`Engines/AdaptivePrescriptionEngine.swift`)

| Desk debt | Prescription |
|---|---|
| `techNeckAndTurtleMinutes > 90` | 2 sets of **Face Pulls / Band Pull-Aparts** with a 2 s hold, pre-workout |
| `leftLeanMinutes` or `rightLeanMinutes > 60` | **Suitcase Carry / Side Plank** on the *opposite* side of the dominant lean. Every unilateral exercise gets **Weak-Side First** (starting side = opposite side) and **Pace Matching** |
| static rigidity > 3 h (`longestStaticStretchMinutes > 180`) | **40 s Couch Stretch** in the first two rest intervals |

Applied adaptations are tagged on `WorkoutSession.appliedDeskAdaptations`, e.g. `["techNeckPullAparts", "lateralLeanCarry.right", "weakSideFirstPaceMatching.right", "staticRigidityCouchStretch"]`.

---

## FlowMac (macOS menu bar)

* **`FlowMacApp.swift`**: `MenuBarExtra` (`.window` style) with `NSApplication.shared.setActivationPolicy(.accessory)`, so there is no Dock icon. The menu bar shows the Flow Score %. The panel (Italian UI) shows the score, the live state, the head ring, the recovery streak, the AirPods and calibration status, the webcam and frontmost-app switches, today's recorded time with a button to open the data folder, and the demo toggle **🧪 Simula Tech Neck (>45s)** / **✨ Raddrizza Postura**.
* **`FlowController.swift`**: glues `HeadphoneMotionService` → `DeskPostureEngine` → nudges and history, and resets the daily metrics at midnight. Nothing is judged before a calibration. The tone stops as soon as the head leaves the deviation; the recovery (chime, streak) still needs 1.5 s in axis. The demo button injects a −22° flexion and a +7° right roll and fast-forwards past 45 s. "Raddrizza" removes the injection.
* **`HeadPostureView.swift`**: Face ID enrollment-style ring. Radial ticks stretch and light up toward where the head tilts (green in axis, orange in between, red deviating), a spirit-level dot shows the head, and the ring redraws at display rate from a non-observable state written at 50 Hz.
* **`CalibrationHUD.swift`**: click-through HUD in the upper third of the main screen (eye level) for the guided calibration: the webcam preview inside the ring like Face ID, the live cue checklist, the ring filling during the 3 s hold, a "Tink" when it locks.
* **`CameraPostureCapture.swift`**: AVCapture session + Vision analysis at ~10 Hz, running only during calibration.
* **`PostureHistoryRecorder.swift`**: feeds the history aggregator, tracker and store; flushes on quit.
* **`PeripheralOverlayWindow.swift`**: a `@MainActor` controller that creates one `.borderless`, `.clear`, `.screenSaver`-level, `ignoresMouseEvents = true` window per `NSScreen.screens` entry and draws a progressive peripheral vignette. **Currently switched off** (`showsPeripheralOverlay = false`): the spatial tone is the only nudge.
* **`SpatialMagneticAudioEngine.swift`**: `AVAudioEngine` + `AVAudioSourceNode` generating a pure 432 Hz sine in real time (20 ms amplitude glide, no clicks), routed in mono into an `AVAudioEnvironmentNode` with `.HRTFHQ`. The source sits 1.5 m behind the nape (`z = 1.5`) and moves on X opposite to the head's roll. The **Dopamine Chime** is `NSSound(named: "Glass")` on recovery.
* `Info.plist` (with `NSMotionUsageDescription`, `NSCameraUsageDescription` and `LSUIElement`) is embedded in the executable via `-sectcreate __TEXT __info_plist`, so CoreMotion can request access when the app runs straight from `swift run`.

## Tests

`Packages/BiomechanicsCore/Tests/BiomechanicsCoreTests` uses swift-testing. Every signal is synthetic and seeded (SplitMix64 + Box-Muller), so runs are fully deterministic.

| Suite | Covers |
|---|---|
| `RetroactiveRingBuffer` | 250-sample capacity, overflow order, concurrent writers, **rep 1 recovered when rep 2 fires Auto-Start**, single movements ignored |
| `Pipeline A` | `a_vert` projection; naive integration drifts (> 0.35 m/s) while **ZUPT + linear dedrifting** ends at exactly 0; 7 ZUPT windows ≥ 150 ms; MCV within 5% of 0.625 m/s under a 0.05 m/s² bias + noise; eccentric time, excursion, femur ROM; touch-and-go reps |
| `Pipeline B and auto-routing` | 10/10 curl reps counted; squats rejected by B; **squats → A, curls → B**; femur rotation forces A; buffer → router; async == sync |
| `Flow Score` | weights, cheat penalties, tempo CV, empty set |
| `DeskPostureEngine` | full **neutral → drifting → magneticNudge → dopamineRecovery → neutral** cycle; drifting recovery; motion gate (accel + gyro); EMA step; **turtle signature** and its negative case; lateral lean; demo fast-forward; summary mapping |
| `Quaternion + calibration` | Euler round-trip; relative attitude near gimbal lock; 10 s seated detection + P85 baseline; reference kept across brief movements; **guided 3 s hold with AirPods worn crooked**; hold restarts on movement; timeout; guided-only mode reopens at the next sit-down; simulated head; standing up |
| `Webcam-assisted calibration` | upright posture ready; no face; blocking vs advisory cues; missing shoulders; the gate pauses and resumes the hold |
| `Posture history` | per-minute categories, states and percentiles; short minutes dropped; dominant app and roll; sitting sessions and breaks; nudge/recovery/relapse events; store round-trip and torn lines; 90-day compaction |
| `AdaptivePrescriptionEngine` | each rule in isolation, dominant lean, combined tags, session score |

## Known limits

* The `@Model` branch of `FlowModels.swift` compiles only on a toolchain with the SwiftData macro plugin (any Xcode). On Command Line Tools the plain-class fallback with the same API is used.
* Gym Pocket Mode lives in `BiomechanicsCore` (engines, models, tests). The iOS/watchOS front-end that feeds it is not part of this repository yet.
* Detection thresholds come from the v3.0 spec and are validated on synthetic signals only, not yet on recorded AirPods data.
* The webcam cues and their thresholds are estimates for a laptop camera and have not been validated on live video yet.
* When FlowMac runs from Terminal (`make run`), macOS attributes the camera and motion permissions to Terminal.
