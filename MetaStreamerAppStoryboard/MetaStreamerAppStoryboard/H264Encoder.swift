// H264Encoder.swift — StreamerApp
// Hardware H264 encoder via VideoToolbox.
// Produces Annex-B NAL units (SPS, PPS, IDR, non-IDR) via delegate callbacks.

import VideoToolbox
import CoreMedia
import CoreVideo

// MARK: - Delegate
protocol H264EncoderDelegate: AnyObject {
    /// Called once at the start and after every IDR frame — send before IDR payload.
    func encoder(_ encoder: H264Encoder, didOutputSPS sps: Data, pps: Data)

    /// Called for every encoded NAL unit.
    /// - Parameters:
    ///   - nalData:  Annex-B bytes (starts with 0x00 0x00 0x00 0x01)
    ///   - nalType:  parsed H264NALType
    ///   - pts:      presentation timestamp
    ///   - isKeyFrame: true for IDR slices
    func encoder(_ encoder: H264Encoder,
                 didOutputNALUnit nalData: Data,
                 nalType: H264NALType,
                 pts: CMTime,
                 isKeyFrame: Bool)
}

// MARK: - H264Encoder
final class H264Encoder {

    weak var delegate: H264EncoderDelegate?

    // MARK: State
    private var compressionSession: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var lastSPS: Data?
    private var lastPPS: Data?
    private let encoderQueue = DispatchQueue(label: "com.glasses.encoder", qos: .userInteractive)

    // Annex-B start code: 0x00 0x00 0x00 0x01
    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    // MARK: - Setup

    func configure(width: Int = VideoConstants.width, height: Int = VideoConstants.height) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width:  Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,          // nil = let system choose (prefers hardware)
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw EncoderError.sessionCreationFailed(status)
        }
        compressionSession = session
        try applyEncoderProperties(session: session, width: width, height: height)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private func applyEncoderProperties(session: VTCompressionSession, width: Int, height: Int) throws {
        var err: OSStatus

        // Real-time encoding — critical for live streaming
        err = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        guard err == noErr else { throw EncoderError.propertySetFailed("RealTime", err) }

        // Profile: Baseline for widest decoder compatibility; Main for slightly better compression
        err = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                   value: kVTProfileLevel_H264_Main_AutoLevel)
        guard err == noErr else { throw EncoderError.propertySetFailed("ProfileLevel", err) }

        // Target bitrate: 4 Mbps for 720p30
        let bitrate = VideoConstants.targetBitrate as CFNumber
        err = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate)
        guard err == noErr else { throw EncoderError.propertySetFailed("AverageBitRate", err) }

        // Data rate limits — allows ~1 MB / 0.1 s burst window
        let dataRateLimits: [NSNumber] = [
            NSNumber(value: VideoConstants.targetBitrate / 8),
            NSNumber(value: 1)
        ]
        err = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                   value: dataRateLimits as CFArray)
        _ = err   // best-effort

        // IDR interval: one keyframe every N frames
        let gop = VideoConstants.keyFrameInterval as CFNumber
        err = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop)
        guard err == noErr else { throw EncoderError.propertySetFailed("MaxKeyFrameInterval", err) }

        // Force parameter-set attachment per IDR
        if #available(iOS 17.0, *) {
            VTSessionSetProperty(session,
                                 key: kVTCompressionPropertyKey_H264EntropyMode,
                                 value: kVTH264EntropyMode_CABAC)
        }

        // Allow frame reordering = false — keeps latency minimal (no B-frames)
        err = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                                   value: kCFBooleanFalse)
        _ = err

        // Enable hardware acceleration explicitly
        err = VTSessionSetProperty(session, key: kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
                                   value: kCFBooleanTrue)
        _ = err
    }

    // MARK: - Encode

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = compressionSession else { return }
        frameCount += 1

        // Force an IDR every keyFrameInterval frames
        var frameProperties: CFDictionary?
        if frameCount % Int64(VideoConstants.keyFrameInterval) == 1 {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer:        pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration:           CMTime(value: 1, timescale: CMTimeScale(VideoConstants.frameRate)),
            frameProperties:    frameProperties,
            sourceFrameRefcon:  nil,
            infoFlagsOut:       nil
        )

        if status != noErr {
            NSLog("[H264Encoder] VTCompressionSessionEncodeFrame error: %d", status)
        }
    }

    // MARK: - Stop

    func invalidate() {
        guard let session = compressionSession else { return }
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
    }

    // MARK: - Encoder output callback (C function)

    private let encoderOutputCallback: VTCompressionOutputCallback = { refcon, _, status, infoFlags, sampleBuffer in
        guard let refcon,
              status == noErr,
              let sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.handleEncodedSampleBuffer(sampleBuffer)
    }

    // MARK: - Sample buffer processing

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]

        let isKeyFrame = !(attachments?.compactMap { $0[kCMSampleAttachmentKey_NotSync] as? Bool }.contains(true) ?? false)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Extract SPS & PPS from format description on every IDR
        if isKeyFrame {

            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                return
            }

            var spsPointer: UnsafePointer<UInt8>?
            var spsSize: Int = 0

            var ppsPointer: UnsafePointer<UInt8>?
            var ppsSize: Int = 0

            var parameterSetCount: Int = 0
            var nalHeaderLength: Int32 = 0

            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            )

            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalHeaderLength
            )

            if let sps = spsPointer, let pps = ppsPointer {

                let spsData = Data(bytes: sps, count: spsSize)
                let ppsData = Data(bytes: pps, count: ppsSize)
                delegate?.encoder(self, didOutputNALUnit: spsData, nalType: .sps, pts: pts, isKeyFrame: isKeyFrame)
                delegate?.encoder(self, didOutputNALUnit: ppsData, nalType: .pps, pts: pts, isKeyFrame: isKeyFrame)
            }
        }

        // Extract NAL units from the sample buffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        var offset = 0

        while offset < totalLength {

            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer! + offset, 4)

            nalLength = CFSwapInt32BigToHost(nalLength)

            let nalStart = dataPointer! + offset + 4
            let nalData = Data(bytes: nalStart, count: Int(nalLength))

            let nalType = nalData.first! & 0x1F

            print("[Encoder] NALU type:", nalType, "size:", nalData.count)

            delegate?.encoder(self, didOutputNALUnit: nalData, nalType: H264NALType(rawValue: nalType) ?? .idr, pts: pts, isKeyFrame: isKeyFrame)
            offset += 4 + Int(nalLength)
        }
    }

    private func extractParameterSets(from desc: CMFormatDescription, pts: CMTime) {
        var spsData: UnsafePointer<UInt8>?
        var spsLen  = 0
        var ppsData: UnsafePointer<UInt8>?
        var ppsLen  = 0
        var paramCount = 0

        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: 0,
                                                           parameterSetPointerOut: &spsData,
                                                           parameterSetSizeOut: &spsLen,
                                                           parameterSetCountOut: &paramCount,
                                                           nalUnitHeaderLengthOut: nil)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(desc, parameterSetIndex: 1,
                                                           parameterSetPointerOut: &ppsData,
                                                           parameterSetSizeOut: &ppsLen,
                                                           parameterSetCountOut: nil,
                                                           nalUnitHeaderLengthOut: nil)

        guard let spsPtr = spsData, let ppsPtr = ppsData else { return }

        var sps = H264Encoder.startCode; sps.append(Data(bytes: spsPtr, count: spsLen))
        var pps = H264Encoder.startCode; pps.append(Data(bytes: ppsPtr, count: ppsLen))

        // Only emit if changed
        if sps != lastSPS || pps != lastPPS {
            lastSPS = sps; lastPPS = pps
            delegate?.encoder(self, didOutputSPS: sps, pps: pps)
        }
    }

    // MARK: - Helpers
    private func bigEndianUInt32(from pointer: UnsafeMutablePointer<CChar>, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { dest in
            dest.copyBytes(from: UnsafeRawBufferPointer(start: pointer.advanced(by: offset),
                                                        count: 4))
        }
        return UInt32(bigEndian: value)
    }
}

// MARK: - Errors
extension H264Encoder {
    enum EncoderError: LocalizedError {
        case sessionCreationFailed(OSStatus)
        case propertySetFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let s): return "VTCompressionSession create failed: \(s)"
            case .propertySetFailed(let k, let s): return "Property \(k) failed: \(s)"
            }
        }
    }
}
