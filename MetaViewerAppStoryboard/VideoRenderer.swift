// VideoRenderer.swift — ViewerApp
// Renders decoded CVPixelBuffers using AVSampleBufferDisplayLayer.
// This is the same layer used by FaceTime and Meta View — hardware-composited,
// sub-frame latency presentation.

import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

// MARK: - VideoRenderer
final class VideoRenderer: UIView {

    // MARK: - Layer
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    // MARK: - State
    private var hasReceivedFirstFrame = false
    private(set) var renderedFrameCount = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill

        // Present frames as soon as they arrive — don't buffer for re-ordering
        // (we send in order over UDP; no B-frames thanks to AllowFrameReordering=false)
        if #available(iOS 17.0, *) {
            displayLayer.preventsCapture = false
        }

        // Register for layer-failed notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayerFailure),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: displayLayer
        )
    }

    // MARK: - Render

    /// Enqueues a CMSampleBuffer for display.
    /// Must be called from ANY thread — AVSampleBufferDisplayLayer is thread-safe.
    func render(sampleBuffer: CMSampleBuffer) {
        // If layer is in failed state, recover
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        displayLayer.enqueue(sampleBuffer)

        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            DispatchQueue.main.async { self.alpha = 1 }
        }
        renderedFrameCount += 1
    }

    /// Convenience: render from a raw CVPixelBuffer by wrapping it in a CMSampleBuffer
    func render(pixelBuffer: CVPixelBuffer,
                presentationTime: CMTime,
                formatDescription: CMFormatDescription?) {
        guard let fmtDesc = formatDescription else { return }

        var timingInfo = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: CMTimeScale(VideoConstants.frameRate)),
            presentationTimeStamp:  presentationTime,
            decodeTimeStamp:        .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator:          kCFAllocatorDefault,
            imageBuffer:        pixelBuffer,
            dataReady:          true,
            makeDataReadyCallback: nil,
            refcon:             nil,
            formatDescription:  fmtDesc,
            sampleTiming:       &timingInfo,
            sampleBufferOut:    &sampleBuffer
        )

        guard status == noErr, let sb = sampleBuffer else { return }

        // Set display-immediately attachment
        if let attachArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        render(sampleBuffer: sb)
    }

    // MARK: - Control

    func flush() {
        displayLayer.flush()
        hasReceivedFirstFrame = false
        renderedFrameCount    = 0
    }

    func flushAndRemoveImage() {
        displayLayer.flushAndRemoveImage()
        hasReceivedFirstFrame = false
        renderedFrameCount    = 0
    }

    // MARK: - Layer failure recovery

    @objc private func handleLayerFailure(_ notification: Notification) {
        NSLog("[VideoRenderer] Layer decode failed — flushing and recovering")
        DispatchQueue.main.async { [weak self] in
            self?.displayLayer.flush()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
