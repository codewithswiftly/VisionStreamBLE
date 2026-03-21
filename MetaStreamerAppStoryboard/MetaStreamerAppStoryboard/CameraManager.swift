// CameraManager.swift — StreamerApp
// Owns the AVCaptureSession and delivers raw CVPixelBuffers at 30 fps.

import AVFoundation
import CoreVideo

// MARK: - Delegate protocol
protocol CameraManagerDelegate: AnyObject {
    /// Called on a dedicated serial queue — do NOT update UI here.
    func cameraManager(_ manager: CameraManager,
                       didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
                       presentationTime: CMTime)
}

// MARK: - CameraManager
final class CameraManager: NSObject {

    weak var delegate: CameraManagerDelegate?

    private let captureSession  = AVCaptureSession()
    private let videoOutput     = AVCaptureVideoDataOutput()
    private let sessionQueue    = DispatchQueue(label: "com.glasses.camera.session",   qos: .userInitiated)
    private let outputQueue     = DispatchQueue(label: "com.glasses.camera.output",    qos: .userInteractive)

    /// AVCaptureVideoPreviewLayer wired to our session (set after configure())
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    // MARK: - Statistics (read from any thread, updated atomically)
    private(set) var capturedFrameCount: Int = 0

    // MARK: - Setup

    /// Call once before startCapture().  Throws on permission denial or hardware error.
    func configure() throws {
        try checkCameraPermission()

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // 720p preset — closest to smart-glasses resolution
        captureSession.sessionPreset = .hd1280x720

        // Input device: rear wide-angle camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back)
        else { throw CameraError.deviceNotFound }

        // Lock frame rate to exactly 30 fps
        try device.lockForConfiguration()
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(VideoConstants.frameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration

        // Enable low-light boost on supported devices
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.unlockForConfiguration()

        // Add input
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else { throw CameraError.cannotAddInput }
        captureSession.addInput(input)

        // Configure video output
        // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange is what VideoToolbox expects
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true    // keep latency low
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard captureSession.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
        captureSession.addOutput(videoOutput)

        // Portrait orientation lock
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = false
            }
        }

        // Build preview layer (must be on main thread for display)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let layer = AVCaptureVideoPreviewLayer(session: self.captureSession)
            layer.videoGravity = .resizeAspectFill
            self.previewLayer = layer
        }
    }

    // MARK: - Control

    func startCapture() {
        sessionQueue.async { [weak self] in
            guard let self, !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    func stopCapture() {
        sessionQueue.async { [weak self] in
            guard let self, self.captureSession.isRunning else { return }
            self.captureSession.stopRunning()
        }
    }

    // MARK: - Private

    private func checkCameraPermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            // This is synchronous via semaphore — acceptable at setup time
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
            sem.wait()
            if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                throw CameraError.permissionDenied
            }
        default:
            throw CameraError.permissionDenied
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        capturedFrameCount += 1
        delegate?.cameraManager(self, didOutputPixelBuffer: pixelBuffer, presentationTime: pts)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Log frame drops for diagnostics
        var mode: CMAttachmentMode = 0
        if let reason = CMGetAttachment(sampleBuffer,
                                        key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                        attachmentModeOut: &mode) as? String {
            NSLog("[CameraManager] Frame dropped: %@", reason)
        }
    }
}

// MARK: - Errors
extension CameraManager {
    enum CameraError: LocalizedError {
        case deviceNotFound
        case cannotAddInput
        case cannotAddOutput
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:   return "Back camera not available"
            case .cannotAddInput:   return "Cannot add camera input"
            case .cannotAddOutput:  return "Cannot add video output"
            case .permissionDenied: return "Camera access denied — enable in Settings"
            }
        }
    }
}
