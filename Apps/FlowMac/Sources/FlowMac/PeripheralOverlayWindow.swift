import AppKit
import Observation
import SwiftUI

/// Shared state between the controller and every per-screen vignette.
@MainActor
@Observable
final class PeripheralOverlayModel {
    /// 0 (invisible) ... 1 (full peripheral vignette).
    var intensity: Double = 0
    /// -1 (head leaning left) ... +1 (leaning right).
    var lateralBias: Double = 0
}

/// Click-through, borderless, transparent windows above everything on every screen,
/// drawing a progressive peripheral vignette while the user is in `magneticNudge`.
@MainActor
final class PeripheralOverlayWindowController {
    private let model = PeripheralOverlayModel()
    private var windows: [NSWindow] = []
    private var isVisible = false
    private var screenObserver: NSObjectProtocol?
    private var hideWorkItem: DispatchWorkItem?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
    }

    func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if windows.isEmpty { rebuildWindows() }
        isVisible = true
        windows.forEach { $0.orderFrontRegardless() }
    }

    /// Fades the vignette out, then removes the windows from screen.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        model.intensity = 0
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.windows.forEach { $0.orderOut(nil) }
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func update(intensity: Double, lateralBias: Double) {
        model.intensity = max(0, min(1, intensity))
        model.lateralBias = max(-1, min(1, lateralBias))
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow(for:))
        if isVisible {
            windows.forEach { $0.orderFrontRegardless() }
        }
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: PeripheralVignetteView(model: model))
        return window
    }
}

/// Peripheral darkening that leaves the centre of vision untouched. The clear centre
/// drifts away from the lean and the leaning side gets heavier, so the comfortable
/// place to look is back in axis.
struct PeripheralVignetteView: View {
    let model: PeripheralOverlayModel

    var body: some View {
        GeometryReader { geometry in
            let diagonal = (geometry.size.width * geometry.size.width + geometry.size.height * geometry.size.height).squareRoot()
            let intensity = model.intensity
            let bias = model.lateralBias
            ZStack {
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.55 - 0.15 * intensity),
                        .init(color: .black.opacity(0.45 * intensity), location: 0.78),
                        .init(color: .black.opacity(0.85 * intensity), location: 1),
                    ],
                    center: UnitPoint(x: 0.5 - 0.12 * bias, y: 0.5),
                    startRadius: 0,
                    endRadius: diagonal / 2
                )
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.5 * intensity * abs(bias)), location: 0),
                        .init(color: .clear, location: 0.35),
                    ],
                    startPoint: bias >= 0 ? .trailing : .leading,
                    endPoint: bias >= 0 ? .leading : .trailing
                )
            }
            .animation(.easeInOut(duration: 0.8), value: intensity)
            .animation(.easeInOut(duration: 0.8), value: bias)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
