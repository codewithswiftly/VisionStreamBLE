// NALUPacketizer.swift — StreamerApp
// Splits H264 NAL units into MTU-safe UDP packets with a fixed header.
//
// Packet layout (NetworkConstants.maxPacketPayload = 1400 bytes payload):
//   [Header 22 bytes] [Payload ≤ 1400 bytes]
//
// For NAL units ≤ 1400 bytes   → single packet  (totalFragments = 1)
// For NAL units  > 1400 bytes  → multiple packets (fragmentIndex 0..N-1)
//
// The receiver reconstructs by collecting all fragments for a given
// (frameIndex, nalType) tuple and concatenating payloads in order.

import Foundation

// MARK: - Output
struct UDPPacket {
    let data: Data          // header + payload, ready to send
    let frameIndex: UInt32
    let nalType: H264NALType
    let isKeyFrame: Bool
}

// MARK: - NALUPacketizer
final class NALUPacketizer {

    private let maxPayload = NetworkConstants.maxPacketPayload
    private var frameCounter: UInt32 = 0

    // MARK: - Packetize

    /// Converts a single Annex-B NAL unit into one or more UDPPackets.
    ///
    /// - Parameters:
    ///   - nalData:    Annex-B data (includes leading 0x00 0x00 0x00 0x01 start code)
    ///   - nalType:    parsed NAL type
    ///   - pts:        presentation timestamp (converted to microseconds)
    ///   - isKeyFrame: whether this NAL belongs to an IDR frame
    func packetize(nalData: Data,
                   nalType: H264NALType,
                   pts: CMTime,
                   isKeyFrame: Bool) -> [UDPPacket] {

        print("[Packetizer] NALU size:", nalData.count)

        // Strip Annex-B start code (4 bytes) before sending
        let payload = stripStartCode(nalData)
        let timestampMicros = UInt64(max(0, pts.seconds * 1_000_000))
        frameCounter += 1

        let flags: UInt8 = isKeyFrame ? PacketFlags.keyFrame : PacketFlags.none

        if payload.count <= maxPayload {
            // Single-packet NAL unit
            let header = UDPPacketHeader(
                frameIndex:     frameCounter,
                timestamp:      timestampMicros,
                nalType:        nalType.rawValue,
                flags:          flags,
                fragmentIndex:  0,
                totalFragments: 1,
                payloadSize:    UInt32(payload.count)
            )
            var packet = header.toData()
            packet.append(payload)
            return [UDPPacket(data: packet, frameIndex: frameCounter,
                              nalType: nalType, isKeyFrame: isKeyFrame)]
        }

        // Fragment large NAL unit (typical for IDR frames at 720p)
        var packets: [UDPPacket] = []
        let totalFragments = UInt16((payload.count + maxPayload - 1) / maxPayload)
        var offset = 0
        var fragmentIndex: UInt16 = 0

        while offset < payload.count {
            let chunkEnd    = min(offset + maxPayload, payload.count)
            let chunk       = payload[offset..<chunkEnd]
            let header      = UDPPacketHeader(
                frameIndex:     frameCounter,
                timestamp:      timestampMicros,
                nalType:        nalType.rawValue,
                flags:          flags,
                fragmentIndex:  fragmentIndex,
                totalFragments: totalFragments,
                payloadSize:    UInt32(chunk.count)
            )
            var packet = header.toData()
            packet.append(chunk)
            packets.append(UDPPacket(data: packet, frameIndex: frameCounter,
                                     nalType: nalType, isKeyFrame: isKeyFrame))
            offset        += chunk.count
            fragmentIndex += 1
        }
        return packets
    }

    // MARK: - Helpers

    /// Strips the 3-byte (00 00 01) or 4-byte (00 00 00 01) Annex-B start code.
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

    func resetFrameCounter() { frameCounter = 0 }
}

// MARK: - CMTime shim (available in both targets via Shared/)
import CoreMedia
