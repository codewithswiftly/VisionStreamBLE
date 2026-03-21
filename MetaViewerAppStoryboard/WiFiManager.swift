// WiFiManager.swift — ViewerApp
// Programmatically joins the streamer's Personal Hotspot via NEHotspotConfiguration.
//
// ⚠️  ENTITLEMENT REQUIRED:
//     Add "com.apple.developer.networking.wifi-info" in Xcode → Signing & Capabilities
//     (Wireless Accessory Configuration capability, or request via Apple developer portal).
//     Without it, the join silently fails on device.
//
// Manual fallback: if the join fails, a prompt guides the user to Settings → WiFi.

import Foundation
import NetworkExtension
import Network
import SystemConfiguration.CaptiveNetwork

// MARK: - Delegate
protocol WiFiManagerDelegate: AnyObject {
    func wifiManager(_ manager: WiFiManager, didJoinSSID ssid: String, assignedIP: String)
    func wifiManager(_ manager: WiFiManager, didFailWithError error: Error)
}

// MARK: - WiFiManager
final class WiFiManager {

    weak var delegate: WiFiManagerDelegate?

    // MARK: - Join

    /// Attempts to join the hotspot. Falls back to Settings prompt if API unavailable.
    func joinHotspot(ssid: String, password: String) {
        NSLog("[WiFiManager] Attempting to join hotspot: %@", ssid)

        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = false   // persistent join, survives app restart

        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error as NSError? {
                    // Error code 13 means "already connected to the requested SSID" — treat as success
                    if error.domain == NEHotspotConfigurationErrorDomain,
                       error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        NSLog("[WiFiManager] Already on correct SSID")
                        self.fetchLocalIPAndNotify()
                        return
                    }
                    NSLog("[WiFiManager] Join failed: %@", error.localizedDescription)
                    // Show manual instructions as fallback
                    self.delegate?.wifiManager(self, didFailWithError: error)
                } else {
                    NSLog("[WiFiManager] Joined hotspot: %@", ssid)
                    self.fetchLocalIPAndNotify()
                }
            }
        }
    }

    // MARK: - IP resolution

    /// Retrieves our assigned IP on the hotspot interface (typically en0)
    func fetchLocalIPAndNotify() {
        // Poll briefly — DHCP can take ~300 ms after joining
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let ip = self.localIPAddress() ?? "unknown"
            NSLog("[WiFiManager] Local IP on hotspot: %@", ip)
            DispatchQueue.main.async {
                self.delegate?.wifiManager(self, didJoinSSID: "", assignedIP: ip)
            }
        }
    }

    /// Returns the IPv4 address of the primary WiFi interface
    func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 = WiFi on iPhone; look for private hotspot range
                if name == "en0" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    // Filter link-local and loopback
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        address = ip
                        break
                    }
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return address
    }

    // MARK: - Current SSID (requires entitlement on iOS 13+)

    func currentSSID() -> String? {
        var ssid: String?
        if let interfaces = CNCopySupportedInterfaces() as? [String] {
            for interface in interfaces {
                if let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any] {
                    ssid = info[kCNNetworkInfoKeySSID as String] as? String
                }
            }
        }
        return ssid
    }
}

// Needed for getifaddrs
import Darwin
