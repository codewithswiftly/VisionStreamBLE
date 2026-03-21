// NALUParser.swift — ViewerApp
// Manages H264 parameter set state and prepares CMSampleBuffers for the decoder.
//
// Responsibilities:
//   1. Cache SPS and PPS NAL units
//   2. Build CMFormatDescription when SPS+PPS are both available
//   3. Build CMBlockBuffer + CMSampleBuffer for each video NAL unit
//   4. Prepend Annex-B start code before presenting to VideoToolbox

import Foundation
import CoreMedia
import VideoToolbox

// MARK: - Delegate
protocol NALUParserDelegate: AnyObject {
    func naluParser(_ parser: NALUParser, didProduceSampleBuffer buffer: CMSampleBuffer, isKeyFrame: Bool)
    func naluParser(_ parser: NALUParser, didUpdateFormatDescription desc: CMFormatDescription)
}

// MARK: - NALUParser
final class NALUParser {

    weak var delegate: NALUParserDelegate?

    // MARK: - State
    private var spsData: Data?
    private var ppsData: Data?
    private var formatDescription: CMFormatDescription?
    private var lastTimestamp: CMTime = .zero

    /// Annex-B start code
    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])

    // MARK: - Process incoming NAL unit
    //
    // `payload` is raw bytes WITHOUT start code (as delivered by UDPReceiver).
    // `header`  carries nalType, timestamp, and keyFrame flag.

    func process(payload: Data, header: UDPPacketHeader) {
        guard !payload.isEmpty else { return }

        let stripped = stripStartCode(payload)
        guard !stripped.isEmpty else { return }

        let nalType = H264NALType.from(byte: stripped[0])
        print("[NALUParser] NALU type:", nalType)

        let pts = CMTime(value: CMTimeValue(header.timestamp),
                             timescale: 1_000_000)    // microseconds → CMTime

        switch nalType {
        case .sps:
            spsData = stripped
            tryRebuildFormatDescription()

        case .pps:
            ppsData = stripped
            tryRebuildFormatDescription()

        case .idr, .nonIDR:
            guard let fmtDesc = formatDescription else {
                // Decoder not ready yet — request an IDR from streamer in production
                NSLog("[NALUParser] Dropped frame — waiting for SPS/PPS")
                return
            }
            let isKeyFrame = (nalType == .idr)
            do {
                let sb = try buildSampleBuffer(payload: stripped,
                                               formatDescription: fmtDesc,
                                               pts: pts,
                                               isKeyFrame: isKeyFrame)
                delegate?.naluParser(self, didProduceSampleBuffer: sb, isKeyFrame: isKeyFrame)
            } catch {
                NSLog("[NALUParser] buildSampleBuffer error: %@", error.localizedDescription)
            }
            lastTimestamp = pts

        default:
            break
        }
    }

    // MARK: - Format description

    private func tryRebuildFormatDescription() {
        guard var sps = spsData, var pps = ppsData else { return }

        // Strip start codes — CMVideoFormatDescriptionCreateFromH264ParameterSets
        // expects raw NALU bytes without start codes
        sps = stripStartCode(sps)
        pps = stripStartCode(pps)

        sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                var parameterSetPointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var parameterSetSizes    = [sps.count, pps.count]

                var fmtDesc: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator:           kCFAllocatorDefault,
                    parameterSetCount:   2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes:   &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fmtDesc
                )

                if status == noErr, let desc = fmtDesc {
                    self.formatDescription = desc
                    NSLog("[NALUParser] FormatDescription built — decoder ready")
                    self.delegate?.naluParser(self, didUpdateFormatDescription: desc)
                } else {
                    NSLog("[NALUParser] FormatDescription create failed: %d", status)
                }
            }
        }
    }

    // MARK: - Sample buffer construction

    private func buildSampleBuffer(payload: Data,
                                   formatDescription: CMFormatDescription,
                                   pts: CMTime,
                                   isKeyFrame: Bool) throws -> CMSampleBuffer {

        // VideoToolbox decoder expects AVCC format (4-byte length prefix), not Annex-B.
        // Convert: strip start code, prepend big-endian uint32 length.
        let nalBytes   = stripStartCode(payload)
        var nalLength  = UInt32(nalBytes.count).bigEndian

        var blockBuffer: CMBlockBuffer?
        var status: OSStatus

        // Combine length prefix + NAL bytes into a single CMBlockBuffer
        let totalSize = 4 + nalBytes.count
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator:           kCFAllocatorDefault,
            memoryBlock:         nil,
            blockLength:         totalSize,
            blockAllocator:      kCFAllocatorDefault,
            customBlockSource:   nil,
            offsetToData:        0,
            dataLength:          totalSize,
            flags:               0,
            blockBufferOut:      &blockBuffer
        )
        guard status == noErr, let blockBuf = blockBuffer else {
            throw ParserError.blockBufferFailed(status)
        }

        // Write length prefix
        status = CMBlockBufferReplaceDataBytes(
            with:              &nalLength,
            blockBuffer:       blockBuf,
            offsetIntoDestination: 0,
            dataLength:        4
        )
        guard status == noErr else { throw ParserError.blockBufferFailed(status) }

        // Write NAL payload
        try nalBytes.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return }
            let err = CMBlockBufferReplaceDataBytes(
                with:              ptr,
                blockBuffer:       blockBuf,
                offsetIntoDestination: 4,
                dataLength:        nalBytes.count
            )
            if err != noErr { throw ParserError.blockBufferFailed(err) }
        }

        // Build CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration:               CMTime(value: 1, timescale: CMTimeScale(VideoConstants.frameRate)),
            presentationTimeStamp:  pts,
            decodeTimeStamp:        .invalid
        )
        var sampleSize = totalSize

        status = CMSampleBufferCreateReady(
            allocator:          kCFAllocatorDefault,
            dataBuffer:         blockBuf,
            formatDescription:  formatDescription,
            sampleCount:        1,
            sampleTimingEntryCount: 1,
            sampleTimingArray:  &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray:    &sampleSize,
            sampleBufferOut:    &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else {
            throw ParserError.sampleBufferFailed(status)
        }

        // Attach display-immediately flag for low latency
        if let attachArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return sb
    }

    // MARK: - Helpers

    private func stripStartCode(_ data: Data) -> Data {
        if data.count >= 4,
           data[0] == 0x00, data[1] == 0x00,
           data[2] == 0x00, data[3] == 0x01 {
            return data.advanced(by: 4)
        }
        if data.count >= 3,
           data[0] == 0x00, data[1] == 0x00, data[2] == 0x01 {
            return data.advanced(by: 3)
        }
        return data
    }

    func reset() {
        spsData            = nil
        ppsData            = nil
        formatDescription  = nil
        lastTimestamp      = .zero
    }
}

// MARK: - Errors
extension NALUParser {
    enum ParserError: LocalizedError {
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .blockBufferFailed(let s):  return "CMBlockBuffer failed: \(s)"
            case .sampleBufferFailed(let s): return "CMSampleBuffer failed: \(s)"
            }
        }
    }
}
