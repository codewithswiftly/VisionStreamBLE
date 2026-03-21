// BLEPeripheralManager.swift — StreamerApp
// Acts as a BLE peripheral ("glasses").
// Advertises WiFi hotspot credentials so the viewer can auto-join.
//
// Flow:
//  1. Viewer central scans and discovers this peripheral
//  2. Viewer connects and reads kWifiCredentialsCharUUID
//  3. Streamer responds with JSON { ssid, password, streamerIP }
//  4. Viewer writes to kStreamReadyCharUUID when connected to hotspot
//  5. Streamer begins UDP stream to viewer's IP

import CoreBluetooth
import Foundation

// MARK: - Delegate
protocol BLEPeripheralManagerDelegate: AnyObject {
    /// Called when the viewer has joined the hotspot and is ready to receive video.
    /// - Parameter viewerIP: IP address of the viewer on the hotspot
    func blePeripheral(_ manager: BLEPeripheralManager, viewerIsReady viewerIP: String)
    func blePeripheralDidUpdateState(_ manager: BLEPeripheralManager, isAdvertising: Bool)
    func blePeripheral(_ manager: BLEPeripheralManager, recievedObject name: String)

}

// MARK: - BLEPeripheralManager
final class BLEPeripheralManager: NSObject {

    weak var delegate: BLEPeripheralManagerDelegate?

    // MARK: - Public config: set BEFORE calling start()
    var wifiSSID:     String = "Rahul's iPhone mini"
    var wifiPassword: String = "1596321456"
    var streamerIP:   String = "172.20.10.1"   // typical Personal Hotspot gateway IP

    // MARK: - Private
    private var peripheralManager: CBPeripheralManager!
    private var wifiCredChar: CBMutableCharacteristic!
    private var streamReadyChar: CBMutableCharacteristic!
    private var streamObjectNameChar: CBMutableCharacteristic!

    private(set) var isAdvertising = false

    // MARK: - Start / Stop

    func start() {
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func stop() {
        if isAdvertising { peripheralManager.stopAdvertising() }
        peripheralManager.removeAllServices()
        isAdvertising = false
        delegate?.blePeripheralDidUpdateState(self, isAdvertising: false)
    }

    // MARK: - Service setup

    private func setupAndStartAdvertising() {
        // WiFi credentials characteristic — readable, notify
        wifiCredChar = CBMutableCharacteristic(
            type:       BLEConstants.wifiCredentialsCharUUID,
            properties: [.read, .notify],
            value:      nil,
            permissions: [.readable]
        )

        // Stream-ready characteristic — writeable (viewer writes its IP)
        streamReadyChar = CBMutableCharacteristic(
            type:       BLEConstants.streamReadyCharUUID,
            properties: [.write, .writeWithoutResponse],
            value:      nil,
            permissions: [.writeable]
        )

        streamObjectNameChar = CBMutableCharacteristic(
            type:       BLEConstants.streamObjectNameCharUUID,
            properties: [.write, .writeWithoutResponse],
            value:      nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(type: BLEConstants.serviceUUID, primary: true)
        service.characteristics = [wifiCredChar, streamReadyChar, streamObjectNameChar]
        peripheralManager.add(service)
    }

    private func startAdvertising() {
        let advertisementData: [String: Any] = [
            CBAdvertisementDataLocalNameKey:    BLEConstants.peripheralName,
            CBAdvertisementDataServiceUUIDsKey: [BLEConstants.serviceUUID]
        ]
        peripheralManager.startAdvertising(advertisementData)
        NSLog("[BLEPeripheral] Advertising as '%@'", BLEConstants.peripheralName)
    }

    // MARK: - Credential payload

    private func credentialsData() -> Data {
        let creds = WiFiCredentials(ssid: wifiSSID, password: wifiPassword, streamerIP: streamerIP)
        return (try? JSONEncoder().encode(creds)) ?? Data()
    }
}

// MARK: - CBPeripheralManagerDelegate
extension BLEPeripheralManager: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            NSLog("[BLEPeripheral] BLE powered on — setting up service")
            setupAndStartAdvertising()
        case .poweredOff:
            NSLog("[BLEPeripheral] BLE powered off")
            isAdvertising = false
            delegate?.blePeripheralDidUpdateState(self, isAdvertising: false)
        case .unauthorized:
            NSLog("[BLEPeripheral] BLE unauthorized — check Info.plist permissions")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            NSLog("[BLEPeripheral] Add service error: %@", error.localizedDescription)
            return
        }
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            NSLog("[BLEPeripheral] Advertising error: %@", error.localizedDescription)
            return
        }
        isAdvertising = true
        delegate?.blePeripheralDidUpdateState(self, isAdvertising: true)
        NSLog("[BLEPeripheral] Advertising started")
    }

    /// Central is reading WiFi credentials
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == BLEConstants.wifiCredentialsCharUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let data = credentialsData()
        if request.offset > data.count {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
        NSLog("[BLEPeripheral] Sent WiFi credentials to central")
    }

    /// Viewer writes its IP address after joining the hotspot
    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == BLEConstants.streamReadyCharUUID,
               let value = request.value,
               let viewerIP = String(data: value, encoding: .utf8) {
                NSLog("[BLEPeripheral] Viewer ready at IP: %@", viewerIP)
                peripheral.respond(to: request, withResult: .success)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.blePeripheral(self, viewerIsReady: viewerIP)
                }
            }
            else if request.characteristic.uuid == BLEConstants.streamObjectNameCharUUID,
                    let value = request.value,
                    let objectName = String(data: value, encoding: .utf8) {
                     NSLog("[BLEPeripheral] Recieved object Name: %@", objectName)
                     peripheral.respond(to: request, withResult: .success)
                     DispatchQueue.main.async { [weak self] in
                         guard let self else { return }
                         self.delegate?.blePeripheral(self, recievedObject: objectName)
                     }
                 }
            else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                continue
            }
        }
    }
}
