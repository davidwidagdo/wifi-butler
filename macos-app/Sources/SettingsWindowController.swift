import Cocoa

// Tabbed settings: Login | Speed Meter | General. Booleans are checkboxes.
// Password is written to the Keychain; the rest to UserDefaults. Start-at-Login
// is toggled via callbacks so the SMAppService logic stays in AppDelegate.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    // Login tab
    private let loginURLField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let passwordPlainField = NSTextField()
    private let revealButton = NSButton()
    private var passwordRevealed = false
    // Set as soon as the user types in either password field. Gates the Keychain
    // write in save() — see the comment there.
    private var passwordEdited = false
    private let extraField = NSTextField()
    private let markerField = NSTextField()
    private let advancedToggle = NSButton(checkboxWithTitle: "Show advanced portal options (rarely needed)", target: nil, action: nil)
    private var advancedBox = NSView()
    private var baseContentHeight: CGFloat = 0

    // Speed Meter tab
    private let showSpeedCheck = NSButton(checkboxWithTitle: "Show speed meter in menu bar", target: nil, action: nil)
    private let intervalPopup = NSPopUpButton()
    private let binaryCheck = NSButton(checkboxWithTitle: "Use binary units (1024 / KiB)", target: nil, action: nil)
    private let interfacePopup = NSPopUpButton()

    // System tab
    private let showSystemCheck = NSButton(checkboxWithTitle: "Show system metrics in the menu", target: nil, action: nil)
    private let showCPUCheck = NSButton(checkboxWithTitle: "Show CPU in menu bar", target: nil, action: nil)
    private let showRAMCheck = NSButton(checkboxWithTitle: "Show RAM in menu bar", target: nil, action: nil)
    private let systemIntervalPopup = NSPopUpButton()

    // General tab
    private let autoLoginCheck = NSButton(checkboxWithTitle: "Auto-Login", target: nil, action: nil)
    private let startAtLoginCheck = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let pollField = NSTextField()

    // Wiring back to AppDelegate.
    var onSave: (() -> Void)?
    var isLoginItemEnabled: () -> Bool = { false }
    var setLoginItem: (Bool) -> Void = { _ in }

    private let intervalOptions = Settings.intervalOptions

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WiFi Butler — Settings"
        self.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
    }

    // MARK: - UI construction

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab("Login", view: buildLoginTab()))
        tabView.addTabViewItem(tab("Speed Meter", view: buildSpeedTab()))
        tabView.addTabViewItem(tab("System", view: buildSystemTab()))
        tabView.addTabViewItem(tab("General", view: buildGeneralTab()))

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let actionBar = GlassPanel.wrap(buttons, cornerRadius: 16, padding: 8)

        content.addSubview(tabView)
        content.addSubview(actionBar)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            actionBar.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])

        sizeWindowToTallestTab(tabView)
    }

    // Measure every tab, not just the selected one: NSTabView lays out only the
    // visible item, so sizing to it would clip the taller tabs.
    private func sizeWindowToTallestTab(_ tabView: NSTabView) {
        guard let content = window?.contentView else { return }
        let selected = tabView.selectedTabViewItem
        var tallest: CGFloat = 0
        for item in tabView.tabViewItems {
            tabView.selectTabViewItem(item)
            content.layoutSubtreeIfNeeded()
            tallest = max(tallest, content.fittingSize.height)
        }
        if let selected = selected { tabView.selectTabViewItem(selected) }
        guard tallest > 0 else { return }
        baseContentHeight = tallest
        window?.setContentSize(NSSize(width: content.frame.width, height: tallest))
    }

    // Expanding the advanced section makes the Login tab taller than the others,
    // so grow past the tallest-tab floor rather than clipping it.
    private func fitWindowToCurrentContent() {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = max(baseContentHeight, content.fittingSize.height)
        guard abs(height - content.frame.height) > 0.5 else { return }
        window?.setContentSize(NSSize(width: content.frame.width, height: height))
    }

    private func tab(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        let container = NSView()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        item.view = container
        return item
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.translatesAutoresizingMaskIntoConstraints = false
        g.rowSpacing = 10
        g.columnSpacing = 10
        g.column(at: 0).xPlacement = .trailing
        return g
    }

    private func buildLoginTab() -> NSView {
        let fields = [loginURLField, usernameField, extraField, markerField]
        for field in fields {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        usernameField.placeholderString = "username"
        loginURLField.placeholderString = "http://<portal-host>/login"
        extraField.placeholderString = "e.g. dst=, popup=true"
        markerField.placeholderString = "e.g. hotspot"

        // Primary — the only fields a normal user needs.
        let primary = grid([
            [label("Username:"), usernameField],
            [label("Password:"), passwordCell()],
        ])

        // Advanced — fallback fields, collapsed by default so the tab isn't
        // cluttered. The app auto-detects and fills the portal's own login form,
        // so these are only used when that fails (e.g. a JS-rendered portal).
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(wrappingLabelWithString:
            "Only used if the portal's login form can't be detected automatically — normally you can leave these alone.")
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let advancedGrid = grid([
            [label("Login URL:"), loginURLField],
            [label("Extra form fields:"), extraField],
            [label("Portal marker:"), markerField],
        ])

        let advancedStack = NSStackView(views: [caption, advancedGrid])
        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 8
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        advancedStack.isHidden = true
        advancedBox = advancedStack

        let column = NSStackView(views: [primary, advancedToggle, advancedStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        return column
    }

    @objc private func toggleAdvanced() {
        advancedBox.isHidden = advancedToggle.state != .on
        fitWindowToCurrentContent()
    }

    private func buildSpeedTab() -> NSView {
        intervalPopup.translatesAutoresizingMaskIntoConstraints = false
        intervalPopup.removeAllItems()
        intervalPopup.addItems(withTitles: ["1 second", "2 seconds", "5 seconds"])

        interfacePopup.translatesAutoresizingMaskIntoConstraints = false
        rebuildInterfacePopup()

        return grid([
            [NSGridCell.emptyContentView, showSpeedCheck],
            [label("Update interval:"), intervalPopup],
            [NSGridCell.emptyContentView, binaryCheck],
            [label("Wi-Fi interface:"), interfacePopup],
        ])
    }

    private func buildSystemTab() -> NSView {
        systemIntervalPopup.translatesAutoresizingMaskIntoConstraints = false
        systemIntervalPopup.removeAllItems()
        systemIntervalPopup.addItems(withTitles: ["1 second", "2 seconds", "5 seconds"])

        let note = NSTextField(wrappingLabelWithString:
            "CPU and RAM always appear in the menu — tick these only to also show them in the menu bar itself.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        // Stays inside the 500pt window once the grid's label column is subtracted.
        note.widthAnchor.constraint(equalToConstant: 300).isActive = true

        return grid([
            [NSGridCell.emptyContentView, showSystemCheck],
            [NSGridCell.emptyContentView, showCPUCheck],
            [NSGridCell.emptyContentView, showRAMCheck],
            [label("Update interval:"), systemIntervalPopup],
            [NSGridCell.emptyContentView, note],
        ])
    }

    private func buildGeneralTab() -> NSView {
        pollField.translatesAutoresizingMaskIntoConstraints = false
        pollField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        pollField.placeholderString = "15"

        let resetButton = NSButton(title: "Reset today's usage", target: self, action: #selector(resetUsage))

        return grid([
            [NSGridCell.emptyContentView, autoLoginCheck],
            [NSGridCell.emptyContentView, startAtLoginCheck],
            [label("Login check interval (s):"), pollField],
            [NSGridCell.emptyContentView, resetButton],
        ])
    }

    private func rebuildInterfacePopup() {
        interfacePopup.removeAllItems()
        interfacePopup.addItem(withTitle: "Automatic (Wi-Fi)")
        interfacePopup.item(at: 0)?.representedObject = ""
        for name in NetworkInterface.all() {
            interfacePopup.addItem(withTitle: name)
            interfacePopup.lastItem?.representedObject = name
        }
    }

    // MARK: - Password reveal (unchanged behavior)

    private func passwordCell() -> NSView {
        passwordPlainField.isHidden = true
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        for field in [passwordField, passwordPlainField] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.delegate = self          // marks the password as user-edited
            holder.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                field.topAnchor.constraint(equalTo: holder.topAnchor),
                field.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
        }
        holder.setContentHuggingPriority(.defaultLow, for: .horizontal)

        revealButton.image = eyeImage(revealed: false)
        revealButton.isBordered = false
        revealButton.imagePosition = .imageOnly
        revealButton.setButtonType(.momentaryChange)
        revealButton.target = self
        revealButton.action = #selector(togglePasswordReveal)
        revealButton.toolTip = "Show/hide password"
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let cell = NSStackView(views: [holder, revealButton])
        cell.orientation = .horizontal
        cell.spacing = 6
        cell.distribution = .fill
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return cell
    }

    private func eyeImage(revealed: Bool) -> NSImage? {
        NSImage(systemSymbolName: revealed ? "eye.slash" : "eye",
                accessibilityDescription: revealed ? "Hide password" : "Show password")
    }

    @objc private func togglePasswordReveal() {
        passwordRevealed.toggle()
        if passwordRevealed {
            passwordPlainField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = passwordPlainField.stringValue
        }
        passwordField.isHidden = passwordRevealed
        passwordPlainField.isHidden = !passwordRevealed
        revealButton.image = eyeImage(revealed: passwordRevealed)
    }

    private var enteredPassword: String {
        passwordRevealed ? passwordPlainField.stringValue : passwordField.stringValue
    }

    // Fetches the stored password off the main thread. A Keychain read blocks its
    // thread for as long as macOS shows an authorization prompt — doing it inline
    // from present() froze the entire app, menu bar and monitors included, until
    // the prompt was answered.
    private func loadPasswordAsync() {
        passwordEdited = false
        passwordField.stringValue = ""
        passwordPlainField.stringValue = ""
        passwordField.placeholderString = "Loading…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stored = Settings.shared.password
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.passwordField.placeholderString = nil
                // The user may have started typing while the Keychain was busy;
                // never overwrite what they entered.
                guard !self.passwordEdited else { return }
                if self.passwordRevealed {
                    self.passwordPlainField.stringValue = stored
                } else {
                    self.passwordField.stringValue = stored
                }
            }
        }
    }

    // MARK: - Load / Save

    private func load() {
        let s = Settings.shared
        loginURLField.stringValue = s.loginURL
        usernameField.stringValue = s.username
        extraField.stringValue = s.extraFields.replacingOccurrences(of: "\n", with: ", ")
        markerField.stringValue = s.portalMarker
        pollField.stringValue = String(s.pollInterval)
        advancedToggle.state = .off
        advancedBox.isHidden = true
        fitWindowToCurrentContent()

        passwordRevealed = false
        passwordField.isHidden = false
        passwordPlainField.isHidden = true
        revealButton.image = eyeImage(revealed: false)
        loadPasswordAsync()

        showSpeedCheck.state = s.showSpeedMeter ? .on : .off
        binaryCheck.state = s.useBinaryUnits ? .on : .off
        intervalPopup.selectItem(at: intervalOptions.firstIndex(of: s.speedInterval) ?? 0)

        showSystemCheck.state = s.showSystemStats ? .on : .off
        showCPUCheck.state = s.showCPUMeter ? .on : .off
        showRAMCheck.state = s.showRAMMeter ? .on : .off
        systemIntervalPopup.selectItem(at: intervalOptions.firstIndex(of: s.systemInterval) ?? 1)

        rebuildInterfacePopup()
        let override = s.wifiInterfaceOverride
        let idx = (0..<interfacePopup.numberOfItems).first {
            (interfacePopup.item(at: $0)?.representedObject as? String) == override
        }
        interfacePopup.selectItem(at: idx ?? 0)

        autoLoginCheck.state = s.autoLoginEnabled ? .on : .off
        startAtLoginCheck.state = isLoginItemEnabled() ? .on : .off
    }

    @objc private func save() {
        // Clicking Save with the mouse doesn't end editing on the focused field,
        // so commit the field editor first — otherwise the last typed-but-uncommitted
        // edit would be read as its previous value.
        window?.makeFirstResponder(nil)

        let s = Settings.shared
        s.loginURL = loginURLField.stringValue.trimmingCharacters(in: .whitespaces)
        s.username = usernameField.stringValue.trimmingCharacters(in: .whitespaces)
        // Only touch the Keychain when the password was actually edited. This is
        // what makes the asynchronous load safe: a field that is empty merely
        // because the Keychain hasn't answered yet can never overwrite the stored
        // password. The write stays synchronous so onSave() below — which can kick
        // off a login — always sees the new value.
        if passwordEdited {
            s.password = enteredPassword
        }
        s.extraFields = extraField.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        s.portalMarker = markerField.stringValue.trimmingCharacters(in: .whitespaces)
        s.pollInterval = Int(pollField.stringValue) ?? 15

        s.showSpeedMeter = showSpeedCheck.state == .on
        s.useBinaryUnits = binaryCheck.state == .on
        s.speedInterval = intervalOptions[safe: intervalPopup.indexOfSelectedItem] ?? 1
        s.wifiInterfaceOverride = (interfacePopup.selectedItem?.representedObject as? String) ?? ""

        s.showSystemStats = showSystemCheck.state == .on
        s.showCPUMeter = showCPUCheck.state == .on
        s.showRAMMeter = showRAMCheck.state == .on
        s.systemInterval = intervalOptions[safe: systemIntervalPopup.indexOfSelectedItem] ?? 2

        s.autoLoginEnabled = autoLoginCheck.state == .on
        setLoginItem(startAtLoginCheck.state == .on)

        onSave?()
        window?.close()
    }

    @objc private func resetUsage() {
        UsageStore.shared.resetToday()
    }

    @objc private func cancel() {
        window?.close()
    }

    // This controller is held for the process's lifetime and the window is never
    // released, so anything left in a field stays in the heap for days. Drop the
    // plaintext password on close; present() reloads it from the Keychain anyway.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === passwordField || field === passwordPlainField else { return }
        passwordEdited = true
    }

    func windowWillClose(_ notification: Notification) {
        passwordField.stringValue = ""
        passwordPlainField.stringValue = ""
        passwordEdited = false
        passwordRevealed = false
        passwordField.isHidden = false
        passwordPlainField.isHidden = true
        revealButton.image = eyeImage(revealed: false)
    }

    func present() {
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
