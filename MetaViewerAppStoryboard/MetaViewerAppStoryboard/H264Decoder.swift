// H264Decoder.swift — ViewerApp
// Hardware H264 decoder via VideoToolbox VTDecompressionSession.
// Accepts CMSampleBuffers and delivers decoded CVPixelBuffers.

import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Delegate
protocol H264DecoderDelegate: AnyObject {
    /// Called on an internal decode queue — dispatch to main for UI.
    func decoder(_ decoder: H264Decoder,
                 didDecodePixelBuffer pixelBuffer: CVPixelBuffer,
                 presentationTime: CMTime)
    func decoder(_ decoder: H264Decoder, didFailWithError error: Error)
}

// MARK: - H264Decoder
final class H264Decoder {

    weak var delegate: H264DecoderDelegate?

    // MARK: - State
    private var decompressionSession: VTDecompressionSession?
    var currentFormatDescription: CMFormatDescription?
    private let decodeQueue = DispatchQueue(label: "com.glasses.decoder", qos: .userInteractive)

    // MARK: - Statistics
    private(set) var decodedFrameCount = 0
    private(set) var droppedFrameCount = 0

    // MARK: - Format description update

    /// Call whenever SPS/PPS change (i.e. a new format description is available)
    func updateFormatDescription(_ formatDescription: CMFormatDescription) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            if let existingDesc = self.currentFormatDescription,
               CMFormatDescriptionEqual(existingDesc, otherFormatDescription: formatDescription) {
                return   // unchanged — no need to recreate session
            }
            self.currentFormatDescription = formatDescription
            do {
                try self.recreateDecompressionSession(formatDescription: formatDescription)
            } catch {
                self.delegate?.decoder(self, didFailWithError: error)
            }
        }
    }

    // MARK: - Decode

    func decode(sampleBuffer: CMSampleBuffer) {
        decodeQueue.async { [weak self] in
            guard let self,
                  let session = self.decompressionSession else {
                NSLog("[H264Decoder] No decompression session — dropping frame")
                return
            }

            var infoFlags = VTDecodeInfoFlags(rawValue: 0)
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags:        [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
                frameRefcon:  nil,
                infoFlagsOut: &infoFlags
            )

            if status != noErr {
                NSLog("[H264Decoder] Decode error: %d", status)
                self.droppedFrameCount += 1
            }
        }
    }

    // MARK: - Flush & invalidate

    func flush() {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        currentFormatDescription = nil
    }

    // MARK: - Session creation

    private func recreateDecompressionSession(formatDescription: CMFormatDescription) throws {
        // Tear down any existing session
        if let old = decompressionSession {
            VTDecompressionSessionInvalidate(old)
            decompressionSession = nil
        }

        // Destination pixel buffer attributes — 420v matches encoder output
        let destinationAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferWidthKey  as String: VideoConstants.width,
            kCVPixelBufferHeightKey as String: VideoConstants.height
        ]

        // Request hardware acceleration at session-creation time (the only place it is honoured;
        // calling VTSessionSetProperty with this key after creation has no effect)
        let decoderSpec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator:                   kCFAllocatorDefault,
            formatDescription:           formatDescription,
            decoderSpecification:        decoderSpec as CFDictionary,
            imageBufferAttributes:       destinationAttrs as CFDictionary,
            outputCallback:              &outputCallback,
            decompressionSessionOut:     &session
        )

        guard status == noErr, let session else {
            throw DecoderError.sessionCreationFailed(status)
        }

        // Real-time decoding hint (applied post-creation — this key is valid here)
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        decompressionSession = session
        NSLog("[H264Decoder] Decompression session created")
    }

    // MARK: - Decoder output callback

    private let decompressionOutputCallback: VTDecompressionOutputCallback = {
        refcon, _, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration in

        guard let refcon else { return }
        let decoder = Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue()

        if status != noErr {
            NSLog("[H264Decoder] Frame decode failed: %d", status)
            decoder.droppedFrameCount += 1
            return
        }

        guard let pixelBuffer = imageBuffer else { return }
        decoder.decodedFrameCount += 1
        decoder.delegate?.decoder(decoder,
                                  didDecodePixelBuffer: pixelBuffer,
                                  presentationTime: presentationTimeStamp)
    }
}

// MARK: - Errors
extension H264Decoder {
    enum DecoderError: LocalizedError {
        case sessionCreationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let s): return "VTDecompressionSession create failed: \(s)"
            }
        }
    }
}
