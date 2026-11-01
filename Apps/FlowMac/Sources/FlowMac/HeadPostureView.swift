import FlowUI
import SwiftUI

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
