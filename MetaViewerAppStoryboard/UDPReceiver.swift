// UDPReceiver.swift — ViewerApp
// Listens on UDP port 5000 and reconstructs fragmented NAL units.
// Delivers complete NAL unit payloads to its delegate.

import Foundation
import Network

// MARK: - Delegate
protocol UDPReceiverDelegate: AnyObject {
    /// Called when all fragments of a NAL unit have been received and assembled.
    /// - Parameters:
    ///   - payload:     Raw H264 bytes (without Annex-B start code)
    ///   - header:      Parsed packet header for the first fragment
    func udpReceiver(_ receiver: UDPReceiver,
                     didReceiveNALUnit payload: Data,
                     header: UDPPacketHeader)

    func udpReceiver(_ receiver: UDPReceiver, didChangeState listening: Bool)
}

// MARK: - Fragment accumulator
private struct FragmentBuffer {
    let header: UDPPacketHeader
    var fragments: [UInt16: Data]   // fragmentIndex → payload
    let totalFragments: UInt16
    let createdAt: Date

    var isComplete: Bool { UInt16(fragments.count) == totalFragments }

    /// Reassemble fragments in order
    func assemble() -> Data {
        var result = Data()
        for idx in 0..<totalFragments {
            if let frag = fragments[idx] { result.append(frag) }
        }
        return result
    }
}

// MARK: - UDPReceiver
final class UDPReceiver {

    weak var delegate: UDPReceiverDelegate?

    // MARK: - State
    private var listener: NWListener?
    private var connection: NWConnection?
    private let receiveQueue = DispatchQueue(label: "com.glasses.udpreceiver", qos: .userInteractive)

    // MARK: - Fragment reassembly
    // Key = (frameIndex << 8) | nalType — collisions are extremely unlikely
    private var fragmentBuffers: [UInt64: FragmentBuffer] = [:]
    private var lastCleanupTime = Date()

    // MARK: - Statistics
    private(set) var receivedPacketCount = 0
    private(set) var lostFrameCount      = 0

    // MARK: - Start / Stop

    func startListening(port: UInt16 = NetworkConstants.udpPort) throws {
        let p = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: p)
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                self.delegate?.udpReceiver(self, didChangeState: state == .ready)
            }
            NSLog("[UDPReceiver] Listener state: %@", "\(state)")
        }

        // Each incoming UDP connection = a datagram from the streamer
        listener?.newConnectionHandler = { [weak self] newConn in
            self?.handleNewConnection(newConn)
        }
        listener?.start(queue: receiveQueue)
        NSLog("[UDPReceiver] Listening on UDP port %d", port)
    }

    func stopListening() {
        listener?.cancel()
        connection?.cancel()
        listener = nil
        connection = nil
        fragmentBuffers.removeAll()
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) {
        // For UDP, keep reading from the same "connection" (remote endpoint)
        connection = conn
        conn.stateUpdateHandler = { state in
            NSLog("[UDPReceiver] Connection state: %@", "\(state)")
        }
        conn.start(queue: receiveQueue)
        receiveLoop(from: conn)
    }

    private func receiveLoop(from conn: NWConnection) {
        // Receive one UDP datagram at a time
        conn.receive(minimumIncompleteLength: NetworkConstants.headerSize,
                     maximumLength: NetworkConstants.headerSize + NetworkConstants.maxPacketPayload + 64) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data = data, !data.isEmpty {
                self.processPacket(data)
            }
            if let error = error {
                NSLog("[UDPReceiver] Receive error: %@", error.localizedDescription)
                return
            }
            // Continue reading
            if !isComplete { self.receiveLoop(from: conn) }
        }
    }

    // MARK: - Packet processing

    private func processPacket(_ data: Data) {
        receivedPacketCount += 1

        guard let header = UDPPacketHeader.from(data: data) else {
            NSLog("[UDPReceiver] Malformed packet (too short)")
            return
        }

        let payloadStart = NetworkConstants.headerSize
        guard data.count >= payloadStart + Int(header.payloadSize) else {
            NSLog("[UDPReceiver] Truncated packet (got %d, expected %d)",
                  data.count, payloadStart + Int(header.payloadSize))
            return
        }

        let payload = data.subdata(in: payloadStart..<(payloadStart + Int(header.payloadSize)))

        // Single-packet NAL unit
        if header.totalFragments == 1 {
            delegate?.udpReceiver(self, didReceiveNALUnit: payload, header: header)
            return
        }

        // Multi-fragment NAL — buffer until complete
        let key = UInt64(header.frameIndex) << 8 | UInt64(header.nalType)
        if fragmentBuffers[key] == nil {
            fragmentBuffers[key] = FragmentBuffer(header: header,
                                                   fragments: [:],
                                                   totalFragments: header.totalFragments,
                                                   createdAt: Date())
        }
        fragmentBuffers[key]?.fragments[header.fragmentIndex] = payload

        if let buffer = fragmentBuffers[key], buffer.isComplete {
            let assembled = buffer.assemble()
            fragmentBuffers.removeValue(forKey: key)
            delegate?.udpReceiver(self, didReceiveNALUnit: assembled, header: buffer.header)
        }

        // Periodic cleanup of stale fragment buffers (>500 ms old)
        periodicCleanup()
    }

    // MARK: - Stale buffer cleanup

    private func periodicCleanup() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanupTime) > 0.5 else { return }
        lastCleanupTime = now

        let staleKeys = fragmentBuffers.filter {
            now.timeIntervalSince($0.value.createdAt) > 0.5
        }.keys

        staleKeys.forEach { key in
            lostFrameCount += 1
            fragmentBuffers.removeValue(forKey: key)
        }

        if !staleKeys.isEmpty {
            NSLog("[UDPReceiver] Cleaned %d stale fragment buffers", staleKeys.count)
        }
    }
}
