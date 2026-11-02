import AppKit
import BiomechanicsCore
import FlowUI
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
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if controller.isCalibrated {
                        HeadPostureView(controller: controller)
                    } else {
                        calibratePrompt
                    }
                }
                .frame(width: 210)

                Divider()

                InsightsView(insights: controller.history.insights)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
        .background(PanelWindowSizer(contentHeight: contentHeight))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Flow Score")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(controller.flowScore)%")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(controller.stateDescription)
                        .font(.callout)
                        .foregroundStyle(stateColor)
                }
            }
            Spacer()
            statusBadge(
                icon: controller.motion.isUsingSimulation ? "waveform.path.ecg" : "airpodspro",
                text: controller.motion.isUsingSimulation ? "Simulazione" : "AirPods live",
                color: controller.motion.isUsingSimulation ? .secondary : .green
            )
            statusBadge(icon: "flame.fill", text: "Streak \(controller.streak)", color: .orange)
            controlsMenu
        }
    }

    private var calibratePrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Calibra per iniziare: siediti dritto e tieni la testa ferma 3 secondi.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Calibra") { controller.recalibrate() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Settings, demo and quit live in one menu so they never take panel space.
    private var controlsMenu: some View {
        Menu {
            Text(controller.calibrationStatus)
            Button(controller.isCalibrated ? "Ricalibra" : "Calibra") { controller.recalibrate() }

            Divider()

            Toggle("Webcam nella calibrazione", isOn: Binding(
                get: { controller.usesCameraForCalibration },
                set: { controller.usesCameraForCalibration = $0 }
            ))
            Toggle("Registra app in primo piano", isOn: Binding(
                get: { controller.history.recordsFrontmostApp },
                set: { controller.history.recordsFrontmostApp = $0 }
            ))
            Button("Apri i dati grezzi") {
                let directory = controller.history.historyDirectory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(directory)
            }

            Divider()

            if controller.isSimulatingTechNeck {
                Button("✨ Raddrizza Postura") { controller.straightenUp() }
            } else {
                Button("🧪 Simula Tech Neck (>\(controller.nudgeAfterSeconds)s)") { controller.simulateTechNeck() }
            }

            Divider()

            Button("Esci") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func statusBadge(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
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

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// `MenuBarExtra` windows grow with their content but never shrink, leaving an empty band
/// on top when a section collapses. This resizes the panel window to the content height,
/// keeping its top edge under the menu bar.
private struct PanelWindowSizer: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = contentHeight
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            var frame = window.frame
            let currentContentHeight = window.contentRect(forFrameRect: frame).height
            let delta = height - currentContentHeight
            guard abs(delta) > 0.5 else { return }
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
