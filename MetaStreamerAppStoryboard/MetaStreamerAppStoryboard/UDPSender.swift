// UDPSender.swift — StreamerApp
// Sends UDP packets to the viewer over the WiFi hotspot.
// Uses Apple's Network framework (NWConnection) — no libdispatch socket API needed.

import Foundation
import Network

// MARK: - Delegate
protocol UDPSenderDelegate: AnyObject {
    func udpSender(_ sender: UDPSender, didChangeState state: NWConnection.State)
    func udpSender(_ sender: UDPSender, didSendPackets count: Int, totalBytes: Int)
}

// MARK: - UDPSender
final class UDPSender {

    weak var delegate: UDPSenderDelegate?

    // MARK: - State
    private var connection: NWConnection?
    private let sendQueue = DispatchQueue(label: "com.glasses.udpsender", qos: .userInteractive)

    // MARK: - Statistics
    private(set) var sentPacketCount = 0
    private(set) var sentByteCount   = 0

    // MARK: - Connect

    /// Establish a UDP connection to the viewer.
    /// - Parameters:
    ///   - host: viewer's IP address on the hotspot (e.g. "172.20.10.2")
    ///   - port: defaults to NetworkConstants.udpPort (5000)
    func connect(to host: String, port: UInt16 = NetworkConstants.udpPort) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        // UDP parameters: disable Nagle (irrelevant for UDP but set explicitly),
        // enable low-latency service class
        let params = NWParameters.udp
        params.serviceClass = .interactiveVideo   // highest priority class

        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            DispatchQueue.main.async {
                self.delegate?.udpSender(self, didChangeState: state)
            }
            if case .failed(let err) = state {
                NSLog("[UDPSender] Connection failed: %@", err.localizedDescription)
                self.reconnect(host: host, port: port)
            }
        }
        connection?.start(queue: sendQueue)
        NSLog("[UDPSender] Connecting to %@:%d", host, port)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: - Send

    /// Fire-and-forget UDP send.  The packet is already serialised by NALUPacketizer.
    func send(packet: UDPPacket) {
        guard let connection,
              case .ready = connection.state else { return }

        let data = packet.data
        connection.send(content: data,
                        completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[UDPSender] Send error: %@", error.localizedDescription)
                return
            }
            self?.sentPacketCount += 1
            self?.sentByteCount   += data.count
        })
    }

    /// Convenience: send multiple packets (e.g. all fragments of one NAL unit)
    func send(packets: [UDPPacket]) {
        packets.forEach { send(packet: $0) }

        let totalBytes = packets.reduce(0) { $0 + $1.data.count }
        delegate?.udpSender(self, didSendPackets: packets.count, totalBytes: totalBytes)
    }

    // MARK: - Reconnection

    private func reconnect(host: String, port: UInt16) {
        sendQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.connect(to: host, port: port)
        }
    }
}
