import AppKit
import AVFoundation
import BiomechanicsCore
import SwiftUI
import Vision

/// Webcam used only while the guided calibration runs. Frames are analysed on-device with
/// Vision (face landmarks + body pose), reduced to a `CameraPostureObservation`, and
/// discarded: nothing is stored or sent anywhere. The session stops as soon as the
/// calibration ends, which also turns the camera LED off.
@MainActor
final class CameraPostureCapture {
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    private(set) var isRunning = false

    private let sessionQueue = DispatchQueue(label: "studio.alexsdop.flow.camera")
    private var session: AVCaptureSession?
    private var analyzer: FrameAnalyzer?

    /// Starts the camera (asking for permission the first time).
    /// - Parameters:
    ///   - onObservation: called on the main actor for each analysed frame (~10 per second).
    ///   - completion: true when the camera is running, false when unavailable or denied.
    func start(onObservation: @escaping (CameraPostureObservation) -> Void, completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(configureAndRun(onObservation: onObservation))
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        completion(granted ? self.configureAndRun(onObservation: onObservation) : false)
                    }
                }
            }
        default:
            completion(false)
        }
    }

    func stop() {
        guard let session else { return }
        isRunning = false
        self.session = nil
        analyzer = nil
        previewLayer = nil
        let box = SessionBox(session: session)
        sessionQueue.async {
            box.session.stopRunning()
        }
    }

    private func configureAndRun(onObservation: @escaping (CameraPostureObservation) -> Void) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        guard session.canAddInput(input) else { return false }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let analyzer = FrameAnalyzer { observation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onObservation(observation) }
            }
        }
        output.setSampleBufferDelegate(analyzer, queue: DispatchQueue(label: "studio.alexsdop.flow.vision"))
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            // Selfie view, like Face ID.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        self.session = session
        self.analyzer = analyzer
        previewLayer = preview
        isRunning = true
        let box = SessionBox(session: session)
        sessionQueue.async {
            box.session.startRunning()
        }
        return true
    }
}

/// AVCaptureSession is documented as safe to start and stop off the main thread
/// (Apple recommends it, since both calls block), but it is not marked Sendable.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

/// Runs Vision on camera frames (on the capture queue) at ~10 Hz.
private final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let deliver: (CameraPostureObservation) -> Void
    private var lastAnalysis: CFTimeInterval = 0
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    init(deliver: @escaping (CameraPostureObservation) -> Void) {
        self.deliver = deliver
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysis >= 0.1, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now

        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest, bodyRequest])
        } catch {
            return
        }
        deliver(Self.observation(
            face: faceRequest.results?.max { $0.boundingBox.width < $1.boundingBox.width },
            body: bodyRequest.results?.first,
            width: width,
            height: height
        ))
    }

    /// Geometry only: angles are computed in pixel space so the frame aspect ratio is respected.
    private static func observation(face: VNFaceObservation?, body: VNHumanBodyPoseObservation?, width: Double, height: Double) -> CameraPostureObservation {
        guard let face else { return CameraPostureObservation(faceDetected: false) }
        let box = face.boundingBox
        var result = CameraPostureObservation(
            faceDetected: true,
            faceYawDegrees: face.yaw.map { $0.doubleValue * 180 / .pi },
            faceCenterX: Double(box.midX),
            faceWidth: Double(box.width)
        )

        if let left = face.landmarks?.leftPupil?.normalizedPoints.first,
           let right = face.landmarks?.rightPupil?.normalizedPoints.first {
            // Landmark points are relative to the face box.
            let leftX = Double(box.minX + left.x * box.width), leftY = Double(box.minY + left.y * box.height)
            let rightX = Double(box.minX + right.x * box.width), rightY = Double(box.minY + right.y * box.height)
            result.eyeLineRollDegrees = lineTilt(dx: (rightX - leftX) * width, dy: (rightY - leftY) * height)
            result.eyeHeight = (leftY + rightY) / 2
        }

        if let body,
           let left = try? body.recognizedPoint(.leftShoulder), left.confidence > 0.3,
           let right = try? body.recognizedPoint(.rightShoulder), right.confidence > 0.3 {
            let dx = Double(right.location.x - left.location.x)
            let dy = Double(right.location.y - left.location.y)
            result.shoulderTiltDegrees = lineTilt(dx: dx * width, dy: dy * height)
            result.shoulderWidth = abs(dx)
        }
        return result
    }

    /// Angle of a line from horizontal, folded into -90...90 so left/right order does not matter.
    private static func lineTilt(dx: Double, dy: Double) -> Double {
        var angle = atan2(dy, dx) * 180 / .pi
        if angle > 90 { angle -= 180 }
        if angle < -90 { angle += 180 }
        return angle
    }
}

/// Circular live preview of the webcam, shown inside the calibration ring.
struct CameraPreviewView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer = layer
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.previewLayer = layer
    }

    final class PreviewHostView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                guard previewLayer !== oldValue else { return }
                oldValue?.removeFromSuperlayer()
                if let previewLayer {
                    wantsLayer = true
                    layer?.addSublayer(previewLayer)
                    needsLayout = true
                }
            }
        }

        override func layout() {
            super.layout()
            previewLayer?.frame = bounds
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
            layer?.masksToBounds = true
        }
    }
}
