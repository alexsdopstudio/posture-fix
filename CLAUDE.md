# CLAUDE.md

Guidance for coding agents working in this repository (Flow v3.0, "Insanely Great Zero-UI Edition").

## Layout

* `Packages/BiomechanicsCore`: shared Swift package (iOS 17+, macOS 14+, tools 5.10, Swift 5 language mode). All signal processing, engines, models and tests.
* `Apps/FlowMac`: macOS 14+ executable package (menu bar app). Depends on `../../Packages/BiomechanicsCore` by path.
* `README.md` documents every algorithm and threshold. Keep it in sync when a threshold changes.

## Commands

```bash
make test    # all BiomechanicsCore tests (swift-testing)
make build   # build FlowMac
make run     # run FlowMac
```

`make test` adds `-Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks` when `xcode-select -p` points at Command Line Tools: without it SwiftPM builds the tests but silently runs none. If you call `swift test` directly on a CLT-only machine, pass that flag yourself and check that the output says `Test run with N tests ... passed`.

## Toolchain rules

* `Packages/BiomechanicsCore/Package.swift` detects a CLT-only toolchain and defines `FLOW_SWIFTDATA_MACROS_UNAVAILABLE`. `Models/FlowModels.swift` keeps two variants of each model, `@Model` and plain class. **Edit both branches together**: same properties, same defaults, same initialisers.
* CloudKit rules for every model: default value on every stored property, optional relationships, no `@Attribute(.unique)`, enums stored as `...Raw: String` with typed accessors in an extension.
* Tests use swift-testing (`import Testing`), not XCTest: XCTest is not available on CLT.

## Engine conventions

* Engines are deterministic: time comes from `IMUSample.timestamp`, never from the wall clock. Randomness in tests and in the simulator comes from `SeededRandom`.
* Units: `userAcceleration` and `gravity` in g, `rotationRate` in rad/s, angles in degrees, `verticalAcceleration` in m/s² (positive up).
* Euler convention: pitch = rotation about X (negative = flexion / looking down), roll = about Y (positive = right), yaw = about Z. Relative attitude is always `current.multiply(byInverseOf: reference)`.
* Every tunable lives in the engine's `Configuration` struct with the spec value as default. Do not hard-code thresholds elsewhere.
* Synthetic test signals must be physically smooth (acceleration starting and ending at 0). Step discontinuities create trapezoid-integration artefacts that look like algorithm bugs.

## FlowMac

* UI strings are Italian (`🧪 Simula Tech Neck (>45s)` / `✨ Raddrizza Postura`).
* `Info.plist` is embedded with `-sectcreate` (see `Apps/FlowMac/Package.swift`) and excluded from sources.
* The audio render block is built in a `nonisolated static` factory and only touches `ToneState`. Keep main-actor state out of it.

## Before pushing

1. `make test` is green with the expected test count.
2. `make build` has no warnings.
3. Commit messages and PRs in English.
