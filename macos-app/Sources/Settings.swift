import Foundation

// App settings. Non-secret values live in UserDefaults; the password lives in
// the Keychain (see Keychain.swift). All fields are editable from the UI.
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let loginURL = "loginURL"
        static let username = "username"
        static let pollInterval = "pollInterval"
        static let extraFields = "extraFields"
        static let portalMarker = "portalMarker"
        static let autoLogin = "autoLoginEnabled"
        static let showSpeedMeter = "showSpeedMeter"
        static let speedInterval = "speedInterval"
        static let useBinaryUnits = "useBinaryUnits"
        static let interfaceOverride = "wifiInterfaceOverride"
        static let showSystemStats = "showSystemStats"
        static let showCPUMeter = "showCPUMeter"
        static let showRAMMeter = "showRAMMeter"
        static let systemInterval = "systemInterval"
        static let initialized = "didInitDefaults"
    }

    private init() {
        guard !defaults.bool(forKey: Key.initialized) else { return }
        defaults.set("", forKey: Key.loginURL)
        defaults.set("", forKey: Key.username)
        defaults.set(15, forKey: Key.pollInterval)
        defaults.set("dst=\npopup=true", forKey: Key.extraFields)
        defaults.set("", forKey: Key.portalMarker)
        defaults.set(true, forKey: Key.autoLogin)
        defaults.set(true, forKey: Key.initialized)
    }

    var loginURL: String {
        get { defaults.string(forKey: Key.loginURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.loginURL) }
    }

    var username: String {
        get { defaults.string(forKey: Key.username) ?? "" }
        set { defaults.set(newValue, forKey: Key.username) }
    }

    var password: String {
        get { Keychain.password() }
        set { Keychain.setPassword(newValue) }
    }

    var pollInterval: Int {
        get { max(5, defaults.integer(forKey: Key.pollInterval)) }
        set { defaults.set(max(5, newValue), forKey: Key.pollInterval) }
    }

    // One "name=value" per line; blank values (e.g. "dst=") are allowed.
    var extraFields: String {
        get { defaults.string(forKey: Key.extraFields) ?? "" }
        set { defaults.set(newValue, forKey: Key.extraFields) }
    }

    // Optional text that must appear on the portal page for login to proceed.
    // Empty means "reachable is enough".
    var portalMarker: String {
        get { defaults.string(forKey: Key.portalMarker) ?? "" }
        set { defaults.set(newValue, forKey: Key.portalMarker) }
    }

    var autoLoginEnabled: Bool {
        get { defaults.bool(forKey: Key.autoLogin) }
        set { defaults.set(newValue, forKey: Key.autoLogin) }
    }

    // Speed meter — new keys use object(forKey:) fallbacks so existing installs
    // (whose didInitDefaults is already true) still get sane defaults.
    var showSpeedMeter: Bool {
        get { defaults.object(forKey: Key.showSpeedMeter) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showSpeedMeter) }
    }

    // The sampling periods offered for both meters, in seconds.
    static let intervalOptions = [1, 2, 5]

    // Seconds between speed samples.
    var speedInterval: Int {
        get {
            let v = defaults.object(forKey: Key.speedInterval) as? Int ?? 1
            return Settings.intervalOptions.contains(v) ? v : 1
        }
        set { defaults.set(newValue, forKey: Key.speedInterval) }
    }

    var useBinaryUnits: Bool {
        get { defaults.object(forKey: Key.useBinaryUnits) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.useBinaryUnits) }
    }

    // Empty means "auto" (use the Wi-Fi interface).
    var wifiInterfaceOverride: String {
        get { defaults.string(forKey: Key.interfaceOverride) ?? "" }
        set { defaults.set(newValue, forKey: Key.interfaceOverride) }
    }

    // System metrics. The dropdown group is on by default — that's the feature —
    // while the menu-bar columns stay off so the bar keeps its current width
    // until the user asks for more.
    var showSystemStats: Bool {
        get { defaults.object(forKey: Key.showSystemStats) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showSystemStats) }
    }

    var showCPUMeter: Bool {
        get { defaults.object(forKey: Key.showCPUMeter) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showCPUMeter) }
    }

    var showRAMMeter: Bool {
        get { defaults.object(forKey: Key.showRAMMeter) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showRAMMeter) }
    }

    // Seconds between system samples. 1s reads as jittery at 9pt, so default to 2.
    var systemInterval: Int {
        get {
            let v = defaults.object(forKey: Key.systemInterval) as? Int ?? 2
            return Settings.intervalOptions.contains(v) ? v : 2
        }
        set { defaults.set(newValue, forKey: Key.systemInterval) }
    }
}
