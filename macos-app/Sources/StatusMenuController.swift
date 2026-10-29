import Cocoa

// Actions that need app-level behavior (login cycle, Keychain, windows) and so
// stay in AppDelegate. Everything purely visual is handled by the controller.
protocol StatusMenuDelegate: AnyObject {
    func statusMenuLoginNow()
    func statusMenuToggleAutoLogin()
    func statusMenuToggleLoginItem()
    func statusMenuOpenUsageHistory()
    func statusMenuOpenSettings()
    func statusMenuWillOpen()
    func statusMenuMetersChanged()
    var isLoginItemEnabled: Bool { get }
}

// Owns the status-bar item: menu construction, the live display lines, and the
// menu-bar image. Keeping this out of AppDelegate leaves that file to the login
// cycle and app lifecycle.
final class StatusMenuController: NSObject {
    weak var delegate: StatusMenuDelegate?

    private var statusItem: NSStatusItem!
    private var isMenuOpen = false

    // Latest values rendered into the menu bar and the display lines.
    private var connState: MenuBarRenderer.State = .connected
    private var statusText = "Checking…"
    private var latestDown: Double = 0
    private var latestUp: Double = 0
    private var latestSystem: SystemMonitor.Sample?
    private var lastRenderKey: String?

    // Top-process listing, refreshed when a process submenu is about to show.
    private var processListing: ProcessStats.Listing?
    private var processFetchInFlight = false

    private let statusMenuItem = NSMenuItem(title: "Status: checking…", action: nil, keyEquivalent: "")
    private let speedLineItem = NSMenuItem(title: "Speed:  —", action: nil, keyEquivalent: "")
    private let todayLineItem = NSMenuItem(title: "Today:  —", action: nil, keyEquivalent: "")

    private let cpuLineItem = NSMenuItem(title: "CPU:  —", action: nil, keyEquivalent: "")
    private let memoryLineItem = NSMenuItem(title: "Memory:  —", action: nil, keyEquivalent: "")
    private let diskLineItem = NSMenuItem(title: "Disk:  —", action: nil, keyEquivalent: "")
    private let uptimeLineItem = NSMenuItem(title: "Uptime:  —", action: nil, keyEquivalent: "")
    private var systemSeparator = NSMenuItem.separator()

    private let cpuSubmenu = NSMenu()
    private let memorySubmenu = NSMenu()

    private let autoLoginItem = NSMenuItem(title: "Auto-Login", action: #selector(toggleAutoLogin), keyEquivalent: "")
    private let loginItemItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let speedMeterItem = NSMenuItem(title: "Speed", action: #selector(toggleSpeedMeter), keyEquivalent: "")
    private let cpuMeterItem = NSMenuItem(title: "CPU", action: #selector(toggleCPUMeter), keyEquivalent: "")
    private let ramMeterItem = NSMenuItem(title: "RAM", action: #selector(toggleRAMMeter), keyEquivalent: "")

    private let topProcessLimit = 3

    // MARK: - Setup

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        renderMenuBar()
        refreshToggleStates()

        // The cached image is drawn at the current display's scale, so a monitor
        // change has to force a redraw — otherwise the skip-if-unchanged check
        // would keep serving an image rendered for the old scale.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        lastRenderKey = nil
        renderMenuBar()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        // Manual enablement: with autoenabling on, AppKit re-derives it on every
        // display and overrides what we set here.
        menu.autoenablesItems = false

        for item in [statusMenuItem, speedLineItem, todayLineItem, diskLineItem, uptimeLineItem] {
            item.isEnabled = false
        }
        menu.addItem(statusMenuItem)
        menu.addItem(speedLineItem)
        menu.addItem(todayLineItem)
        menu.addItem(systemSeparator)

        // CPU and Memory carry submenus, so they stay enabled — which also renders
        // them at full contrast instead of the dimmed disabled treatment.
        cpuSubmenu.delegate = self
        cpuSubmenu.autoenablesItems = false
        cpuLineItem.submenu = cpuSubmenu
        memorySubmenu.delegate = self
        memorySubmenu.autoenablesItems = false
        memoryLineItem.submenu = memorySubmenu
        menu.addItem(cpuLineItem)
        menu.addItem(memoryLineItem)
        menu.addItem(diskLineItem)
        menu.addItem(uptimeLineItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Login Now", action: #selector(loginNow), keyEquivalent: "l"))
        menu.addItem(autoLoginItem)
        menu.addItem(loginItemItem)

        let metersItem = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        let metersMenu = NSMenu()
        metersMenu.autoenablesItems = false
        metersMenu.addItem(speedMeterItem)
        metersMenu.addItem(cpuMeterItem)
        metersMenu.addItem(ramMeterItem)
        metersItem.submenu = metersMenu
        menu.addItem(metersItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Usage History…", action: #selector(openUsageHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        assignTargets(in: menu)
        statusItem.menu = menu
        applySystemRowVisibility()
    }

    // The plain loop only walks top-level items, so submenu entries would be left
    // routing through the responder chain.
    private func assignTargets(in menu: NSMenu) {
        for item in menu.items {
            if item.action != nil && item.target == nil { item.target = self }
            if let submenu = item.submenu { assignTargets(in: submenu) }
        }
    }

    // MARK: - Inputs from the app

    func setStatus(_ state: MenuBarRenderer.State, _ text: String) {
        connState = state
        statusText = text
        statusMenuItem.title = "Status: \(text)"
        renderMenuBar()
    }

    func setSpeed(down: Double, up: Double) {
        latestDown = down
        latestUp = up
        renderMenuBar()
        updateDisplayLines()
    }

    func setSystem(_ sample: SystemMonitor.Sample) {
        latestSystem = sample
        renderMenuBar()
        updateSystemLines()
    }

    // Re-read every toggle from its source of truth. Called at launch, after a
    // settings save, and whenever a toggle is flipped elsewhere.
    func refreshToggleStates() {
        let s = Settings.shared
        autoLoginItem.state = s.autoLoginEnabled ? .on : .off
        speedMeterItem.state = s.showSpeedMeter ? .on : .off
        cpuMeterItem.state = s.showCPUMeter ? .on : .off
        ramMeterItem.state = s.showRAMMeter ? .on : .off
        loginItemItem.state = (delegate?.isLoginItemEnabled ?? false) ? .on : .off
        applySystemRowVisibility()
    }

    func refresh() {
        renderMenuBar()
        updateDisplayLines()
        updateSystemLines()
    }

    private func applySystemRowVisibility() {
        let show = Settings.shared.showSystemStats
        for item in [systemSeparator, cpuLineItem, memoryLineItem, diskLineItem, uptimeLineItem] {
            item.isHidden = !show
        }
    }

    // MARK: - Rendering

    private func renderMenuBar() {
        guard let button = statusItem?.button else { return }
        let columns = meterColumns()

        // Rebuilding the NSImage (lockFocus, text measurement, drawing) is by far
        // the most expensive thing this app does at idle, and it runs 1-2x a
        // second forever. Most ticks produce byte-identical text — a quiet network
        // reads "0 B/s" and CPU rarely moves a whole percent — so skip the redraw
        // whenever nothing visible changed.
        let key = renderKey(columns)
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        button.image = MenuBarRenderer.image(state: connState, columns: columns)
        button.imagePosition = .imageOnly
        button.toolTip = tooltip()
    }

    // Everything that affects the drawn image, cheaply comparable.
    private func renderKey(_ columns: [MenuBarRenderer.Column]) -> String {
        var key = connState.symbol
        for column in columns {
            for row in column.rows {
                key += "\u{1}" + row.label + "\u{2}" + row.value
            }
            key += "\u{3}"
        }
        return key
    }

    // Builds the menu-bar columns from the current settings and latest samples.
    private func meterColumns() -> [MenuBarRenderer.Column] {
        typealias Column = MenuBarRenderer.Column
        let s = Settings.shared
        var columns: [Column] = []

        if s.showSpeedMeter {
            // Upload on top, download below, so each arrow points toward its own row.
            columns.append(Column(rows: [
                Column.Row(label: "", value: "↑ " + ByteFormatter.speed(latestUp, binary: s.useBinaryUnits)),
                Column.Row(label: "", value: "↓ " + ByteFormatter.speed(latestDown, binary: s.useBinaryUnits)),
            ]))
        }

        // CPU and RAM share one column: enabling the second costs no extra width.
        var systemRows: [Column.Row] = []
        if s.showCPUMeter {
            systemRows.append(Column.Row(label: "CPU", value: SystemFormat.percent(latestSystem?.cpuBusy ?? 0)))
        }
        if s.showRAMMeter {
            systemRows.append(Column.Row(label: "RAM", value: SystemFormat.percent(latestSystem?.memory.usedFraction ?? 0)))
        }
        if !systemRows.isEmpty {
            columns.append(Column(rows: systemRows, valueSample: "100%"))
        }
        return columns
    }

    private func tooltip() -> String {
        let s = Settings.shared
        let today = UsageStore.shared.today
        var text = "WiFi Butler — \(statusText) · Today ↓ \(ByteFormatter.total(today.rx, binary: s.useBinaryUnits))"
            + " ↑ \(ByteFormatter.total(today.tx, binary: s.useBinaryUnits))"
        if let sample = latestSystem, s.showSystemStats {
            text += " · CPU \(SystemFormat.percent(sample.cpuBusy))"
                + " · RAM \(SystemFormat.percent(sample.memory.usedFraction))"
        }
        return text
    }

    private func updateDisplayLines() {
        // Nobody can read these while the menu is closed; skip the string building.
        guard isMenuOpen else { return }
        let binary = Settings.shared.useBinaryUnits
        speedLineItem.title = "Speed:  ↓ \(ByteFormatter.speed(latestDown, binary: binary))   ↑ \(ByteFormatter.speed(latestUp, binary: binary))"
        let today = UsageStore.shared.today
        todayLineItem.title = "Today:  ↓ \(ByteFormatter.total(today.rx, binary: binary))   ↑ \(ByteFormatter.total(today.tx, binary: binary))"
    }

    private func updateSystemLines() {
        guard isMenuOpen, Settings.shared.showSystemStats, let sample = latestSystem else { return }
        let binary = Settings.shared.useBinaryUnits

        cpuLineItem.title = "CPU:  \(SystemFormat.percent(sample.cpuBusy))"

        let memory = sample.memory
        memoryLineItem.title = "Memory:  \(ByteFormatter.total(memory.used, binary: binary))"
            + " of \(ByteFormatter.total(memory.total, binary: binary))"
            + " · \(SystemFormat.pressureLabel(memory.pressure))"

        if let disk = sample.disk {
            diskLineItem.title = "Disk:  \(ByteFormatter.total(disk.free, binary: binary)) free"
                + " of \(ByteFormatter.total(disk.total, binary: binary))"
                + " (\(SystemFormat.percent(disk.usedFraction)) used)"
        }
        uptimeLineItem.title = "Uptime:  \(SystemFormat.uptime(sample.uptime))"
    }

    // MARK: - Top processes

    // Fetching shells out to ps (~20 ms), so it runs off the main thread and the
    // submenu shows a placeholder until it lands.
    private func fetchProcesses(then refill: @escaping () -> Void) {
        guard !processFetchInFlight else { return }
        processFetchInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = ProcessStats.listing()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.processListing = listing
                self.processFetchInFlight = false
                refill()
            }
        }
    }

    private func populate(_ menu: NSMenu, byCPU: Bool) {
        menu.removeAllItems()
        guard let listing = processListing else {
            // Never leave a submenu empty — AppKit renders a tiny empty box.
            menu.addItem(disabledItem("Sampling…"))
            return
        }

        let rows = listing.rows.map {
            ProcessMath.Named(pid: $0.pid, name: $0.name,
                              value: byCPU ? $0.cpuCores : Double($0.rss))
        }
        let top = ProcessMath.aggregate(rows, limit: topProcessLimit)
        guard !top.isEmpty else {
            menu.addItem(disabledItem("No data"))
            return
        }

        for row in top {
            let name = row.count > 1 ? "\(row.name) ×\(row.count)" : row.name
            let value = byCPU
                ? SystemFormat.percent(row.value)
                : ByteFormatter.total(UInt64(max(0, row.value)), binary: Settings.shared.useBinaryUnits)
            menu.addItem(disabledItem("\(name)   \(value)"))
        }

        // The libproc fallback can only see this user's processes, so say so
        // rather than presenting a ranking that silently omits WindowServer.
        if !listing.fullCoverage {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Your processes only"))
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions handled here

    @objc private func toggleSpeedMeter() {
        Settings.shared.showSpeedMeter.toggle()
        Log.write("Speed meter \(Settings.shared.showSpeedMeter ? "shown" : "hidden").")
        refreshToggleStates()
        renderMenuBar()
    }

    @objc private func toggleCPUMeter() {
        Settings.shared.showCPUMeter.toggle()
        refreshToggleStates()
        renderMenuBar()
        delegate?.statusMenuMetersChanged()
    }

    @objc private func toggleRAMMeter() {
        Settings.shared.showRAMMeter.toggle()
        refreshToggleStates()
        renderMenuBar()
        delegate?.statusMenuMetersChanged()
    }

    @objc private func openActivityMonitor() {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            Log.write("Activity Monitor not found.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error = error {
                Log.write("Activity Monitor launch failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Actions forwarded to the app
    //
    // Declared here so #selector resolves and the target loop above can point
    // every item at this controller.

    @objc private func loginNow() { delegate?.statusMenuLoginNow() }
    @objc private func toggleAutoLogin() { delegate?.statusMenuToggleAutoLogin() }
    @objc private func toggleLoginItem() { delegate?.statusMenuToggleLoginItem() }
    @objc private func openUsageHistory() { delegate?.statusMenuOpenUsageHistory() }
    @objc private func openSettings() { delegate?.statusMenuOpenSettings() }
}

// MARK: - NSMenuDelegate

extension StatusMenuController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }   // submenus hit this too
        isMenuOpen = true
        delegate?.statusMenuWillOpen()                    // force a fresh sample
        updateDisplayLines()
        updateSystemLines()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        isMenuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === cpuSubmenu || menu === memorySubmenu else { return }
        let byCPU = menu === cpuSubmenu
        populate(menu, byCPU: byCPU)
        // Refresh in the background, then refill once the data lands.
        fetchProcesses { [weak self] in
            guard let self = self else { return }
            self.populate(byCPU ? self.cpuSubmenu : self.memorySubmenu, byCPU: byCPU)
        }
    }
}
