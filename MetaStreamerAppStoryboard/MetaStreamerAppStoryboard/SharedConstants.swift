// SharedConstants.swift
// Shared between StreamerApp and ViewerApp

import Foundation
import CoreBluetooth

// MARK: - BLE UUIDs
enum BLEConstants {
    /// Primary service advertised by the Streamer (glasses)
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")

    /// Characteristic that carries WiFi credentials JSON payload
    static let wifiCredentialsCharUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")

    /// Characteristic used by Viewer to signal "ready to stream"
    static let streamReadyCharUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567892")

    /// Characteristic used by Viewer to signal "ready to stream"
    static let streamObjectNameCharUUID = CBUUID(string: "6c8b0e8d-4f7a-5f42-9c3c-0c2f1d55b20a")

    /// BLE peripheral name used for discovery
    static let peripheralName = "MetaGlasses-Streamer"
}

// MARK: - Networking
enum NetworkConstants {
    /// UDP port for H264 video transport
    static let udpPort: UInt16 = 5000

    /// Maximum UDP payload (MTU-safe for WiFi)
    static let maxPacketPayload = 1400

    /// Header size in bytes
    /// Layout: frameIndex(4) + timestamp(8) + nalType(1) + flags(1) + fragmentIndex(2) + totalFragments(2) + payloadSize(4) = 22 bytes
    static let headerSize = 22
}

// MARK: - Video
enum VideoConstants {
    static let width  = 1280
    static let height = 720
    static let frameRate = 30
    static let targetBitrate = 4_000_000   // 4 Mbps — good for 720p30 over local WiFi
    static let keyFrameInterval = 60        // IDR every 2 seconds
}

// MARK: - WiFi Credential payload
struct WiFiCredentials: Codable {
    let ssid: String
    let password: String
    let streamerIP: String   // streamer's hotspot IP (usually 172.20.10.1)
}

// MARK: - UDP Packet Header
struct UDPPacketHeader {
    var frameIndex:      UInt32   // monotonically increasing frame counter
    var timestamp:       UInt64   // presentation timestamp in microseconds
    var nalType:         UInt8    // H264 NAL unit type (see H264NALType)
    var flags:           UInt8    // PacketFlags bitmask
    var fragmentIndex:   UInt16   // 0-based fragment index within a NALU
    var totalFragments:  UInt16   // total number of fragments for this NALU
    var payloadSize:     UInt32   // length of the payload that follows

    static let size = 22          // must stay in sync with NetworkConstants.headerSize

    /// Serialises header to big-endian bytes
    func toData() -> Data {
        var d = Data(capacity: UDPPacketHeader.size)
        d.appendBigEndian(frameIndex)
        d.appendBigEndian(timestamp)
        d.append(nalType)
        d.append(flags)
        d.appendBigEndian(fragmentIndex)
        d.appendBigEndian(totalFragments)
        d.appendBigEndian(payloadSize)
        return d
    }

    /// Deserialises header from the first 22 bytes of a received packet
    static func from(data: Data) -> UDPPacketHeader? {
        guard data.count >= UDPPacketHeader.size else { return nil }
        var offset = 0
        let fi  = data.readBigEndianUInt32(at: &offset)
        let ts  = data.readBigEndianUInt64(at: &offset)
        let nt  = data[offset]; offset += 1
        let fl  = data[offset]; offset += 1
        let fri = data.readBigEndianUInt16(at: &offset)
        let tfi = data.readBigEndianUInt16(at: &offset)
        let ps  = data.readBigEndianUInt32(at: &offset)
        return UDPPacketHeader(frameIndex: fi, timestamp: ts, nalType: nt,
                               flags: fl, fragmentIndex: fri,
                               totalFragments: tfi, payloadSize: ps)
    }
}

// MARK: - Packet flags
struct PacketFlags {
    static let none:     UInt8 = 0x00
    static let keyFrame: UInt8 = 0x01   // packet belongs to an IDR frame
}

// MARK: - H264 NAL types
enum H264NALType: UInt8 {
    case unspecified = 0
    case nonIDR      = 1    // P/B frame
    case idr         = 5    // IDR (keyframe) slice
    case sps         = 7    // Sequence Parameter Set
    case pps         = 8    // Picture Parameter Set
    case unknown     = 0xFF

    static func from(byte: UInt8) -> H264NALType {
        H264NALType(rawValue: byte & 0x1F) ?? .unknown
    }
}

// MARK: - Data big-endian helpers
extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }
    mutating func appendBigEndian(_ value: UInt64) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 8))
    }
    mutating func appendBigEndian(_ value: UInt16) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 2))
    }

    func readBigEndianUInt32(at offset: inout Int) -> UInt32 {
        let v = UInt32(bigEndian: self[offset..<(offset+4)].withUnsafeBytes { $0.load(as: UInt32.self) })
        offset += 4; return v
    }
    func readBigEndianUInt64(at offset: inout Int) -> UInt64 {
        let v = UInt64(bigEndian: self[offset..<(offset+8)].withUnsafeBytes { $0.load(as: UInt64.self) })
        offset += 8; return v
    }
    func readBigEndianUInt16(at offset: inout Int) -> UInt16 {
        let v = UInt16(bigEndian: self[offset..<(offset+2)].withUnsafeBytes { $0.load(as: UInt16.self) })
        offset += 2; return v
    }
}
