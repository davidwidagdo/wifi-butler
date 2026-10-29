import Foundation
import CoreWLAN
import Darwin

// Resolves which BSD interface to measure. Defaults to the Wi-Fi interface (via
// CoreWLAN), honoring a manual override from Settings, and can list the
// machine's interfaces for the Settings picker.
enum NetworkInterface {
    // The Wi-Fi interface name, e.g. "en0". Falls back to "en0" if CoreWLAN
    // can't tell us (rare).
    static func wifiName() -> String? {
        if let name = CWWiFiClient.shared().interface()?.interfaceName, !name.isEmpty {
            return name
        }
        return "en0"
    }

    // The interface to sample: the Settings override if set, else Wi-Fi.
    static func resolved(override: String) -> String? {
        let o = override.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty, o.lowercased() != "auto" { return o }
        return wifiName()
    }

    // Distinct AF_LINK interface names, for the Settings picker.
    static func all() -> [String] {
        var names: [String] = []
        var ap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ap) == 0 else { return names }
        defer { freeifaddrs(ap) }
        var p = ap
        while let cur = p {
            if let a = cur.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_LINK) {
                let n = String(cString: cur.pointee.ifa_name)
                if !names.contains(n) { names.append(n) }
            }
            p = cur.pointee.ifa_next
        }
        return names
    }
}
