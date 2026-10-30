import Cocoa
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = PortalClient()
    private var timer: Timer?
    private var settingsWC: SettingsWindowController?
    private var usageHistoryWC: UsageHistoryWindowController?

    private let menuController = StatusMenuController()
    private let speedMonitor = SpeedMonitor()
    private let systemMonitor = SystemMonitor()

    private var isBusy = false

    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.davidwidagdo.wifiautologin.path")
    private var lastEventCheck = Date.distantPast

    // Portals often answer the first probes with a bare redirect or no reply; retry soon.
    private static let quickRetryDelay: TimeInterval = 3
    private static let quickRetryLimit = 4
    private var quickRetriesLeft = 0
    private static let captivePopupBundleID = "com.apple.CaptiveNetworkAssistant"

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        menuController.delegate = self
        menuController.install()
        Log.write("App started.")
        startSpeedMonitor()
        startSystemMonitor()
        startMonitoring()
        startEventTriggers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageStore.shared.flush()
        Log.write("App quitting.")
    }

    // MARK: - Speed monitor

    private func startSpeedMonitor() {
        speedMonitor.onUpdate = { [weak self] sample in
            self?.menuController.setSpeed(down: sample.down, up: sample.up)
        }
        speedMonitor.start()
    }

    private func startSystemMonitor() {
        systemMonitor.onUpdate = { [weak self] sample in
            self?.menuController.setSystem(sample)
        }
        guard Settings.shared.showSystemStats else { return }
        systemMonitor.start()
    }

    // Off entirely when the user has hidden system metrics — no timer, no cost.
    private func syncSystemMonitor() {
        if Settings.shared.showSystemStats {
            systemMonitor.restart()
        } else {
            systemMonitor.stop()
        }
    }

    // MARK: - Event triggers

    private func startEventTriggers() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { self?.triggerCheck(reason: "network available") }
        }
        pathMonitor.start(queue: monitorQueue)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        triggerCheck(reason: "system woke")
        // A multi-hour sleep makes the CPU delta meaningless and can shift
        // kern.boottime, so drop the baselines and re-read boot time.
        syncSystemMonitor()
    }

    private func triggerCheck(reason: String) {
        guard Settings.shared.autoLoginEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastEventCheck) > 2 else { return }
        lastEventCheck = now
        quickRetriesLeft = Self.quickRetryLimit
        Log.write("Trigger (\(reason)) — checking session.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.checkAndLogin()
        }
    }

    // MARK: - Main menu (Edit menu keeps copy/paste working in Settings)

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Login cycle

    private func startMonitoring() {
        timer?.invalidate()
        timer = nil
        checkAndLogin()
        guard Settings.shared.autoLoginEnabled else { return }
        let interval = TimeInterval(Settings.shared.pollInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkAndLogin()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkAndLogin() {
        guard Settings.shared.autoLoginEnabled else {
            refreshStatus()
            return
        }
        runCycle(manual: false)
    }

    private func refreshStatus() {
        guard !isBusy else { return }
        client.checkConnectivity { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if state == .connected {
                    self.menuController.setStatus(.connected, "Connected")
                } else {
                    self.menuController.setStatus(.disconnected, "Logged out (auto-login off)")
                }
            }
        }
    }

    private func runCycle(manual: Bool) {
        guard !isBusy else { return }
        isBusy = true
        client.checkConnectivity { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if state == .connected {
                    self.menuController.setStatus(.connected, "Connected")
                    self.quickRetriesLeft = 0
                    self.dismissCaptivePopup()
                    self.finishCycle()
                    return
                }
                self.client.inspectCaptivePage { [weak self] ours, page in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if ours, page?.isLoggedIn == true {
                            self.menuController.setStatus(.connected, "Connected")
                            self.quickRetriesLeft = 0
                            self.dismissCaptivePopup()
                            self.finishCycle()
                            return
                        }
                        guard ours, let page = page else {
                            self.menuController.setStatus(.disconnected, "Idle — no portal on this network")
                            let detail = page.map { "not our portal page (\($0.summary))" }
                                ?? "no captive page (offline or still joining)"
                            Log.write(manual ? "Manual login: \(detail) — nothing to do." : "No internet, \(detail) — skipping.")
                            self.finishCycle()
                            self.scheduleQuickRetry()
                            return
                        }
                        self.quickRetriesLeft = 0
                        self.menuController.setStatus(.working, "Logging in…")
                        Log.write(manual ? "Manual login — submitting." : "Captive portal detected — logging in.")
                        self.performLogin(page: page)
                    }
                }
            }
        }
    }

    private func performLogin(page: CaptivePage) {
        client.login(page: page) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.client.confirmLogin { loggedIn in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        if loggedIn {
                            self.menuController.setStatus(.connected, "Connected")
                            Log.write("Login OK.")
                            self.dismissCaptivePopup()
                        } else {
                            self.menuController.setStatus(.disconnected, "Login failed — check Settings")
                            Log.write("Login FAILED — check credentials / Login URL / Extra fields.")
                        }
                        self.finishCycle()
                    }
                }
            }
        }
    }

    private func finishCycle() {
        isBusy = false
    }

    private func scheduleQuickRetry() {
        guard quickRetriesLeft > 0 else { return }
        quickRetriesLeft -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quickRetryDelay) { [weak self] in
            self?.checkAndLogin()
        }
    }

    // Only called once the session is confirmed, when the macOS portal popup is stale.
    private func dismissCaptivePopup() {
        let popups = NSRunningApplication.runningApplications(withBundleIdentifier: Self.captivePopupBundleID)
        guard !popups.isEmpty else { return }
        popups.forEach { if !$0.terminate() { $0.forceTerminate() } }
        Log.write("Closed the macOS captive-portal popup.")
    }

    // MARK: - Login Items

    private func setLoginItem(_ on: Bool) {
        do {
            if on, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
                Log.write("Added to Login Items.")
            } else if !on, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Log.write("Removed from Login Items.")
            }
        } catch {
            Log.write("Login Item toggle failed: \(error.localizedDescription)")
        }
        menuController.refreshToggleStates()
    }
}

// MARK: - StatusMenuDelegate

extension AppDelegate: StatusMenuDelegate {
    var isLoginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func statusMenuLoginNow() {
        Log.write("Manual login requested.")
        runCycle(manual: true)
    }

    func statusMenuToggleAutoLogin() {
        let enabled = !Settings.shared.autoLoginEnabled
        Settings.shared.autoLoginEnabled = enabled
        menuController.refreshToggleStates()
        Log.write("Auto-login \(enabled ? "enabled" : "disabled").")
        startMonitoring()
    }

    func statusMenuToggleLoginItem() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
    }

    func statusMenuOpenUsageHistory() {
        if usageHistoryWC == nil { usageHistoryWC = UsageHistoryWindowController() }
        usageHistoryWC?.present()
    }

    func statusMenuOpenSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController()
        }
        settingsWC?.isLoginItemEnabled = { [weak self] in self?.isLoginItemEnabled ?? false }
        settingsWC?.setLoginItem = { [weak self] on in self?.setLoginItem(on) }
        settingsWC?.onSave = { [weak self] in
            guard let self = self else { return }
            Log.write("Settings updated.")
            self.menuController.refreshToggleStates()
            self.startMonitoring()
            self.speedMonitor.restart()
            self.syncSystemMonitor()
            self.menuController.refresh()
        }
        settingsWC?.present()
    }

    // Opening the dropdown forces a fresh sample so nothing on screen is stale.
    func statusMenuWillOpen() {
        guard Settings.shared.showSystemStats else { return }
        systemMonitor.refreshNow()
    }

    // A menu-bar meter was toggled; start the monitor if it wasn't running.
    func statusMenuMetersChanged() {
        syncSystemMonitor()
    }
}
