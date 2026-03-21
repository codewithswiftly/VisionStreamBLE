// BLECentralManager.swift — ViewerApp
// Scans for the streamer peripheral, connects, and retrieves WiFi credentials.
// After joining the hotspot, writes the viewer's IP back to the streamer.

import CoreBluetooth
import Foundation

// MARK: - Delegate
protocol BLECentralManagerDelegate: AnyObject {
    /// Credentials received — caller should now join the hotspot
    func bleCentral(_ manager: BLECentralManager, didReceiveCredentials credentials: WiFiCredentials)

    /// State updates for UI feedback
    func bleCentral(_ manager: BLECentralManager, didUpdateStatus status: BLEScanStatus)
}

enum BLEScanStatus {
    case idle
    case scanning
    case connecting
    case connected
    case credentialsReceived
    case error(String)
}

// MARK: - BLECentralManager
final class BLECentralManager: NSObject {

    weak var delegate: BLECentralManagerDelegate?

    // MARK: - Private state
    private var centralManager: CBCentralManager!
    private var discoveredPeripheral: CBPeripheral?
    private var wifiCredChar: CBCharacteristic?
    private var streamReadyChar: CBCharacteristic?
    private(set) var receivedCredentials: WiFiCredentials?
    private var scanTimer: Timer?

    // MARK: - Public

    func startScanning() {
        centralManager = CBCentralManager(delegate: self, queue: .main,
                                          options: [CBCentralManagerOptionShowPowerAlertKey: true])
        updateStatus(.scanning)
    }

    func stopScanning() {
        centralManager?.stopScan()
        scanTimer?.invalidate()
    }

    /// After joining the hotspot, call this to notify the streamer
    func notifyStreamerReady(viewerIP: String) {
        guard let peripheral = discoveredPeripheral,
              let char = streamReadyChar,
              peripheral.state == .connected else {
            NSLog("[BLECentral] Cannot notify — not connected to peripheral")
            return
        }
        let data = viewerIP.data(using: .utf8) ?? Data()
        // Use write without response for speed (fire-and-forget)
        peripheral.writeValue(data, for: char, type: .withoutResponse)
        NSLog("[BLECentral] Notified streamer, viewer IP: %@", viewerIP)
    }

    func disconnect() {
        if let p = discoveredPeripheral { centralManager?.cancelPeripheralConnection(p) }
    }

    // MARK: - Private

    private func doScan() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        // Timeout after 15 s
        scanTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.discoveredPeripheral == nil else { return }
            self.centralManager.stopScan()
            self.updateStatus(.error("Glasses not found — ensure BLE is on and in range"))
        }
        NSLog("[BLECentral] Scanning for '%@'…", BLEConstants.peripheralName)
    }

    private func updateStatus(_ status: BLEScanStatus) {
        delegate?.bleCentral(self, didUpdateStatus: status)
    }
}

// MARK: - CBCentralManagerDelegate
extension BLECentralManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            doScan()
        case .poweredOff:
            updateStatus(.error("Bluetooth is off — enable it in Settings"))
        case .unauthorized:
            updateStatus(.error("Bluetooth access denied — check Info.plist"))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown"
        guard name == BLEConstants.peripheralName || name.contains("Glasses") else { return }

        NSLog("[BLECentral] Found peripheral: %@ (RSSI: %@)", name, RSSI)
        central.stopScan()
        scanTimer?.invalidate()
        discoveredPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        updateStatus(.connecting)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[BLECentral] Connected to %@", peripheral.name ?? "peripheral")
        updateStatus(.connected)
        peripheral.discoverServices([BLEConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        updateStatus(.error("Connection failed: \(error?.localizedDescription ?? "unknown")"))
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        NSLog("[BLECentral] Disconnected from peripheral")
        discoveredPeripheral = nil
        updateStatus(.idle)
    }
}

// MARK: - CBPeripheralDelegate
extension BLECentralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLEConstants.serviceUUID {
            peripheral.discoverCharacteristics(
                [BLEConstants.wifiCredentialsCharUUID, BLEConstants.streamReadyCharUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == BLEConstants.wifiCredentialsCharUUID {
                wifiCredChar = char
                peripheral.readValue(for: char)   // triggers didUpdateValueFor
            }
            if char.uuid == BLEConstants.streamReadyCharUUID {
                streamReadyChar = char
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BLEConstants.wifiCredentialsCharUUID,
              let data = characteristic.value else { return }

        do {
            let creds = try JSONDecoder().decode(WiFiCredentials.self, from: data)
            receivedCredentials = creds
            NSLog("[BLECentral] Received credentials — SSID: %@", creds.ssid)
            updateStatus(.credentialsReceived)
            delegate?.bleCentral(self, didReceiveCredentials: creds)
        } catch {
            updateStatus(.error("Could not decode credentials: \(error.localizedDescription)"))
        }
    }
}
