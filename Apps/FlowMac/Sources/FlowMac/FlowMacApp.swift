import AppKit
import BiomechanicsCore
import SwiftUI

@main
struct FlowMacApp: App {
    @NSApplicationDelegateAdaptor(FlowAppDelegate.self) private var appDelegate
    @State private var controller = FlowController()

    var body: some Scene {
        MenuBarExtra {
            FlowMenuView(controller: controller)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.state == .magneticNudge ? "figure.stand.line.dotted.figure.stand" : "figure.mind.and.body")
                Text("\(controller.flowScore)%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class FlowAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct FlowMenuView: View {
    let controller: FlowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flow Score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(controller.flowScore)%")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(controller.stateDescription)
                    .font(.callout)
                    .foregroundStyle(stateColor)
            }

            Divider()

            HeadPostureView(controller: controller)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Streak recuperi: \(controller.streak)", systemImage: "flame.fill")
                Label(controller.airPodsStatus, systemImage: controller.motion.isUsingSimulation ? "waveform.path.ecg" : "airpodspro")
                Label(controller.calibrationStatus, systemImage: "scope")
            }
            .font(.callout)

            Divider()

            if controller.isSimulatingTechNeck {
                Button("✨ Raddrizza Postura") { controller.straightenUp() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            } else {
                Button("🧪 Simula Tech Neck (>\(controller.nudgeAfterSeconds)s)") { controller.simulateTechNeck() }
                    .buttonStyle(.borderedProminent)
            }

            Toggle("Webcam nella calibrazione", isOn: Binding(
                get: { controller.usesCameraForCalibration },
                set: { controller.usesCameraForCalibration = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)

            Divider()

            HStack {
                Label("Storico oggi: \(Self.duration(controller.history.todayRecordedSeconds))", systemImage: "chart.xyaxis.line")
                Spacer()
                Button {
                    controller.history.revealInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Apri la cartella dei dati")
            }
            .font(.callout)

            Toggle("Registra app in primo piano", isOn: Binding(
                get: { controller.history.recordsFrontmostApp },
                set: { controller.history.recordsFrontmostApp = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)

            HStack {
                Button(controller.isCalibrated ? "Ricalibra" : "Calibra") { controller.recalibrate() }
                Spacer()
                Button("Esci") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private var stateColor: Color {
        switch controller.state {
        case .neutral: return .secondary
        case .drifting: return .orange
        case .magneticNudge: return .red
        case .dopamineRecovery: return .green
        }
    }
}
