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
                Button("🧪 Simula Tech Neck (>45s)") { controller.simulateTechNeck() }
                    .buttonStyle(.borderedProminent)
            }

            HStack {
                Button("Ricalibra") { controller.recalibrate() }
                Spacer()
                Button("Esci") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
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
