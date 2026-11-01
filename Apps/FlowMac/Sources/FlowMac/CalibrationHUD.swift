import AppKit
import AVFoundation
import BiomechanicsCore
import FlowUI
import Observation
import SwiftUI

/// Webcam side of the guided calibration, observed by the HUD.
@MainActor
@Observable
final class CameraCalibrationModel {
    var isActive = false
    var previewLayer: AVCaptureVideoPreviewLayer?
    var cues: [PostureCue] = []
    /// True while the webcam is holding the calibration until the posture is right.
    var isHoldingForPosture = false

    func reset() {
        isActive = false
        previewLayer = nil
        cues = []
        isHoldingForPosture = false
    }
}

/// Apple-style HUD shown when the AirPods are put on: "sit upright, look at this ring,
/// hold still". It sits in the upper third of the main screen, where the eyes should
/// rest, so the calibrated neutral is aligned with the screen. Click-through.
@MainActor
final class CalibrationHUDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private let ringState: HeadRingState
    private let thresholds: RingThresholds
    private let camera: CameraCalibrationModel

    init(ringState: HeadRingState, thresholds: RingThresholds, camera: CameraCalibrationModel) {
        self.ringState = ringState
        self.thresholds = thresholds
        self.camera = camera
    }

    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    /// - Parameter delay: keeps the HUD up a little longer (e.g. to show "Calibrated").
    func hide(after delay: TimeInterval = 0) {
        guard let panel, panel.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.35
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if panel.alphaValue == 0 { panel.orderOut(nil) }
                    }
                })
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 340, height: 500)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 28
        blur.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: CalibrationHUDView(state: ringState, thresholds: thresholds, camera: camera))
        hosting.frame = blur.bounds
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        panel.contentView = blur
        return panel
    }

    /// Centred horizontally, ring at roughly the upper third of the screen (eye level).
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.64 - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

struct CalibrationHUDView: View {
    let state: HeadRingState
    let thresholds: RingThresholds
    let camera: CameraCalibrationModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let progress = state.calibrationProgress
            let calibrated = progress == nil && state.calibratedAt.map { timeline.date.timeIntervalSince($0) < 3 } == true
            VStack(spacing: 14) {
                Text(calibrated ? "Postura calibrata" : "Calibra la postura")
                    .font(.system(size: 17, weight: .semibold))
                ZStack {
                    HeadRingView(state: state, thresholds: thresholds, drawsCenter: camera.previewLayer == nil)
                    if let layer = camera.previewLayer {
                        CameraPreviewView(layer: layer)
                            .frame(width: 140, height: 140)
                            .clipShape(Circle())
                            .opacity(calibrated ? 0.4 : 1)
                    }
                }
                .frame(width: 240, height: 240)
                Text(instruction(progress: progress, calibrated: calibrated))
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .frame(height: 34)
                cueList
                    .font(.system(size: 11))
                    .opacity(calibrated ? 0 : 1)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func instruction(progress: Double?, calibrated: Bool) -> String {
        if calibrated { return "Da adesso questa è la tua postura corretta." }
        if camera.isHoldingForPosture { return "Sistema la postura come indicato qui sotto." }
        guard let progress, progress > 0.02 else { return "Siediti dritto e guarda il cerchio." }
        return progress < 0.98 ? "Perfetto, resta così…" : "Fatto."
    }

    @ViewBuilder
    private var cueList: some View {
        if camera.isActive && !camera.cues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(camera.cues, id: \.kind) { cue in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: cue))
                            .foregroundStyle(color(for: cue))
                        Text(Self.text(for: cue))
                            .foregroundStyle(cue.isSatisfied ? .secondary : .primary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                staticCue("Schiena appoggiata, spalle rilassate")
                staticCue("Orecchie sopra le spalle, mento appena indietro")
                staticCue("Sguardo su questo cerchio")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func staticCue(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
            Text(text)
        }
    }

    private func icon(for cue: PostureCue) -> String {
        if cue.isSatisfied { return "checkmark.circle.fill" }
        return cue.isBlocking ? "exclamationmark.circle.fill" : "lightbulb"
    }

    private func color(for cue: PostureCue) -> Color {
        if cue.isSatisfied { return .green }
        return cue.isBlocking ? .orange : .yellow
    }

    static func text(for cue: PostureCue) -> String {
        let value = cue.measured ?? 0
        switch (cue.kind, cue.isSatisfied) {
        case (.faceVisible, true): return "Ti vedo"
        case (.faceVisible, false): return "Non ti vedo: mettiti davanti allo schermo"
        case (.headLevel, true): return "Testa dritta"
        case (.headLevel, false): return String(format: "Raddrizza la testa (inclinata di %.0f°)", value)
        case (.facingScreen, true): return "Viso rivolto allo schermo"
        case (.facingScreen, false): return "Gira il viso verso lo schermo"
        case (.centered, true): return "Centrato davanti allo schermo"
        case (.centered, false): return "Spostati al centro dello schermo"
        case (.shouldersLevel, true): return "Spalle allineate"
        case (.shouldersLevel, false): return String(format: "Allinea le spalle (%.0f° di differenza)", value)
        case (.distance, true): return "Distanza dallo schermo giusta"
        case (.distance, false): return cue.direction < 0 ? "Allontanati un po' dallo schermo" : "Avvicinati un po' allo schermo"
        case (.chinTuck, true): return "Testa sopra le spalle"
        case (.chinTuck, false): return "Porta il mento un po' indietro"
        case (.screenHeight, true): return "Schermo all'altezza degli occhi"
        case (.screenHeight, false): return "Lo schermo è basso: alzalo verso gli occhi"
        }
    }
}
