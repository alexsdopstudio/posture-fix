import BiomechanicsCore
import FlowUI
import SwiftUI

struct PostureTab: View {
    let controller: PhonePostureController
    @AppStorage("showsPhoneControls") private var showsControls = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    if controller.isCalibrated {
                        HeadRingView(state: controller.headRing, thresholds: controller.ringThresholds)
                            .frame(width: 260, height: 260)
                        HStack(spacing: 28) {
                            readout("Avanti/indietro", controller.headPitchDeviation)
                            readout("Laterale", controller.headRoll)
                        }
                    } else {
                        calibratePrompt
                    }

                    DisclosureGroup("Controlli", isExpanded: $showsControls) {
                        controls.padding(.top, 8)
                    }
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding()
            }
            .navigationTitle("Postura")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flow Score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(controller.flowScore)%")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(controller.stateDescription)
                    .foregroundStyle(stateColor)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                badge(
                    icon: controller.motion.isUsingSimulation ? "waveform.path.ecg" : "airpodspro",
                    text: controller.motion.isUsingSimulation ? "Simulazione" : "AirPods live",
                    color: controller.motion.isUsingSimulation ? .secondary : .green
                )
                badge(icon: "flame.fill", text: "Streak \(controller.streak)", color: .orange)
            }
        }
    }

    private var calibratePrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Calibra per iniziare: siediti dritto, tieni il telefono all'altezza degli occhi e resta fermo 3 secondi.")
                .multilineTextAlignment(.center)
            Button("Calibra") { controller.recalibrate() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 30)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(controller.isCalibrated ? "Ricalibra" : "Calibra") { controller.recalibrate() }
            if controller.isSimulatingTechNeck {
                Button("✨ Raddrizza Postura") { controller.straightenUp() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                Text("Simulazione attiva: −22° avanti, +7° laterale")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Button("🧪 Simula Tech Neck (>\(controller.nudgeAfterSeconds)s)") { controller.simulateTechNeck() }
            }
            Text("Il monitoraggio funziona con l'app aperta. Su iPhone il richiamo è il tono spaziale negli AirPods più una vibrazione al recupero.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func readout(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%+.0f°", value))
                .font(.title3.weight(.medium))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func badge(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var stateColor: Color {
        guard controller.isCalibrated else { return .secondary }
        switch controller.state {
        case .neutral: return .secondary
        case .drifting: return .orange
        case .magneticNudge: return .red
        case .dopamineRecovery: return .green
        }
    }
}

/// Guided calibration on iPhone: the same 3 s steady hold as on the Mac, without webcam.
struct CalibrationSheet: View {
    let controller: PhonePostureController

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let progress = controller.headRing.calibrationProgress
            let calibrated = progress == nil
                && controller.headRing.calibratedAt.map { timeline.date.timeIntervalSince($0) < 3 } == true
            VStack(spacing: 18) {
                Text(calibrated ? "Postura calibrata" : "Calibra la postura")
                    .font(.title2.weight(.semibold))
                HeadRingView(state: controller.headRing, thresholds: controller.ringThresholds)
                    .frame(width: 230, height: 230)
                Text(instruction(progress: progress, calibrated: calibrated))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Schiena appoggiata, spalle rilassate", systemImage: "checkmark.circle")
                    Label("Orecchie sopra le spalle, mento appena indietro", systemImage: "checkmark.circle")
                    Label("Telefono all'altezza degli occhi", systemImage: "checkmark.circle")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .opacity(calibrated ? 0 : 1)
            }
            .padding(24)
        }
    }

    private func instruction(progress: Double?, calibrated: Bool) -> String {
        if calibrated { return "Da adesso questa è la tua postura corretta." }
        guard let progress else { return "Indossa gli AirPods per calibrare." }
        if progress <= 0.02 { return "Siediti dritto e resta fermo." }
        return progress < 0.98 ? "Perfetto, resta così…" : "Fatto."
    }
}
