import SwiftUI

/// How the engine judges the head right now.
enum HeadStatus {
    case inAxis, between, deviating

    var color: Color {
        switch self {
        case .inAxis: return .green
        case .between: return .orange
        case .deviating: return .red
        }
    }
}

/// Latest head reading, written on every motion sample and read by the ring at display
/// rate. Deliberately not observable: SwiftUI never diffs 50 Hz updates.
@MainActor
final class HeadRingState {
    /// Raw pitch relative to the neutral, degrees (negative = looking down).
    var pitchDeviation: Double = 0
    /// Raw roll, degrees (positive = leaning right).
    var roll: Double = 0
    var status: HeadStatus = .inAxis
    /// Guided calibration hold progress 0...1; nil when not calibrating.
    var calibrationProgress: Double?
    var calibratedAt: Date?
}

/// Engine thresholds the ring draws against.
struct RingThresholds {
    var techNeck: Double
    var lateral: Double
    var pitchTolerance: Double
    var rollTolerance: Double
}

/// Face ID enrollment-style ring: radial ticks stretch and light up toward where the head
/// is tilting, a dot shows the head like a spirit level. During guided calibration the
/// ring fills clockwise while the head is held steady and empties when it moves.
struct HeadRingView: View {
    let state: HeadRingState
    let thresholds: RingThresholds
    /// False when something else (the webcam preview) fills the centre of the ring.
    var drawsCenter = true

    private static let tickCount = 72
    private static let baseTickLength = 9.0
    /// Longest stretch a tick can get; the ring radius leaves room for it so nothing is clipped.
    private static let maxTickStretch = 18.0

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - Self.baseTickLength - Self.maxTickStretch - 3
        let inner = radius * 0.62

        // Head tilt normalised so that 1 = warning threshold, in screen space (y down = looking down).
        let vx = state.roll / thresholds.lateral
        let vy = -state.pitchDeviation / thresholds.techNeck
        let magnitude = (vx * vx + vy * vy).squareRoot()
        let direction = atan2(vy, vx)
        let color = state.status.color

        let sinceCalibration = state.calibratedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let scanPhase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        let isCalibrating = state.calibrationProgress != nil
        let holdProgress = state.calibrationProgress ?? 0

        for index in 0..<Self.tickCount {
            let fraction = Double(index) / Double(Self.tickCount)
            let angle = fraction * 2 * .pi - .pi / 2
            var length = Self.baseTickLength
            var tickColor = Color.primary.opacity(0.18)

            if isCalibrating && holdProgress < 0.02 {
                // Waiting for a steady head: a soft highlight travels around the ring.
                let distance = abs(((fraction - scanPhase + 1.5).truncatingRemainder(dividingBy: 1)) - 0.5)
                let glow = max(0, 1 - distance * 8)
                length += 6 * glow
                tickColor = Color.primary.opacity(0.18 + 0.6 * glow)
            } else if isCalibrating {
                // Holding steady: the ring fills clockwise from the top.
                if fraction <= holdProgress {
                    tickColor = .green
                    length += 4
                }
            } else if sinceCalibration < 0.6 {
                // Just locked: the whole ring glows green for a moment.
                tickColor = .green
                length += 4 * (1 - sinceCalibration / 0.6)
            } else {
                // Live: ticks toward the tilt direction stretch and take the status colour.
                let alignment = max(0, cos(angle - direction))
                let activation = magnitude > 0.08 ? pow(alignment, 8) * min(1.4, magnitude) : 0
                length += Self.maxTickStretch * min(1, activation)
                if state.status == .inAxis {
                    tickColor = Color.green.opacity(0.45 + 0.55 * min(1, activation))
                } else {
                    tickColor = activation > 0.05 ? color.opacity(0.35 + 0.65 * min(1, activation)) : Color.primary.opacity(0.18)
                }
            }

            let start = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let end = CGPoint(x: center.x + cos(angle) * (radius + length), y: center.y + sin(angle) * (radius + length))
            var tick = Path()
            tick.move(to: start)
            tick.addLine(to: end)
            context.stroke(tick, with: .color(tickColor), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }

        guard drawsCenter else { return }

        // Warning boundary (thin) and in-axis zone (faint fill).
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)),
            with: .color(.primary.opacity(0.12)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
        )
        let zoneX = inner * thresholds.rollTolerance / thresholds.lateral
        let zoneY = inner * thresholds.pitchTolerance / thresholds.techNeck
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - zoneX, y: center.y - zoneY, width: zoneX * 2, height: zoneY * 2)),
            with: .color(.green.opacity(0.10))
        )

        // Spirit-level dot: where the head points, relative to the neutral.
        // While calibrating there is no neutral yet: a white dot just shows the head is tracked.
        let dotColor = isCalibrating ? Color.white : color
        let reach = min(magnitude, 1.45)
        let dot = CGPoint(
            x: center.x + (magnitude > 0 ? vx / magnitude : 0) * reach * inner,
            y: center.y + (magnitude > 0 ? vy / magnitude : 0) * reach * inner
        )
        var glow = context
        glow.addFilter(.blur(radius: 8))
        glow.fill(Path(ellipseIn: CGRect(x: dot.x - 11, y: dot.y - 11, width: 22, height: 22)), with: .color(dotColor.opacity(0.7)))
        context.fill(Path(ellipseIn: CGRect(x: dot.x - 6.5, y: dot.y - 6.5, width: 13, height: 13)), with: .color(dotColor))
        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)), with: .color(.primary.opacity(0.4)))
    }
}

/// Ring + compact readout for the menu bar panel.
struct HeadPostureView: View {
    let controller: FlowController

    var body: some View {
        VStack(spacing: 10) {
            HeadRingView(state: controller.headRing, thresholds: controller.ringThresholds)
                .frame(width: 236, height: 236)
                // Movement pauses the posture timers: a small icon on the ring, never a layout change.
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "pause.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(controller.isMotionGated ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: controller.isMotionGated)
                        .help("Ti stai muovendo: il giudizio della postura è in pausa")
                }
                .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                readout("Avanti/indietro", controller.headPitchDeviation)
                readout("Laterale", controller.headRoll)
                readout("Rotazione", controller.headYaw)
            }
            .font(.caption)
            .monospacedDigit()
        }
    }

    private func readout(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 1) {
            Text(String(format: "%+.0f°", value))
                .font(.callout.weight(.medium))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
