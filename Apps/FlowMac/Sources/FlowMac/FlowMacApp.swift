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
    /// The settings and demo controls are tucked away by default.
    @AppStorage("showsControls") private var showsControls = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flow Score")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(controller.flowScore)%")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(controller.stateDescription)
                        .font(.callout)
                        .foregroundStyle(stateColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    statusBadge(
                        icon: controller.motion.isUsingSimulation ? "waveform.path.ecg" : "airpodspro",
                        text: controller.motion.isUsingSimulation ? "Simulazione" : "AirPods live",
                        color: controller.motion.isUsingSimulation ? .secondary : .green
                    )
                    statusBadge(icon: "flame.fill", text: "Streak \(controller.streak)", color: .orange)
                }
            }

            if controller.isCalibrated {
                HeadPostureView(controller: controller)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Calibra per iniziare: siediti dritto e tieni la testa ferma 3 secondi.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    Button("Calibra") { controller.recalibrate() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Divider()

            InsightsView(insights: controller.history.insights)

            Divider()

            DisclosureGroup(isExpanded: $showsControls) {
                controls
                    .padding(.top, 8)
            } label: {
                Text("Controlli")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Esci") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(16)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
        .background(PanelWindowSizer(contentHeight: contentHeight))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(controller.calibrationStatus, systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(controller.isCalibrated ? "Ricalibra" : "Calibra") { controller.recalibrate() }

            Toggle("Webcam nella calibrazione", isOn: Binding(
                get: { controller.usesCameraForCalibration },
                set: { controller.usesCameraForCalibration = $0 }
            ))
            Toggle("Registra app in primo piano", isOn: Binding(
                get: { controller.history.recordsFrontmostApp },
                set: { controller.history.recordsFrontmostApp = $0 }
            ))

            Button {
                let directory = controller.history.historyDirectory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(directory)
            } label: {
                Label("Apri i dati grezzi", systemImage: "folder")
            }

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
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
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
