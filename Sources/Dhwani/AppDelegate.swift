import AppKit
import ServiceManagement

@available(macOS 26.0, *)
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let dictation = DictationController()
    private var accessibilityRetryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy would double-paste every dictation.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
        setupStatusItem()
        setupDictation()
        onboardIfNeeded()
        startHotkeysWhenTrusted()
        dictation.prepare()
    }

    // MARK: - Wiring

    private func setupDictation() {
        dictation.onStateChange = { [weak self] state in
            self?.refreshIcon(for: state)
        }
    }

    private func startHotkeysWhenTrusted() {
        // "In flight" includes .processing so Escape can still cancel after the
        // key is released, before the text lands.
        hotkeys.isRecording = { [weak self] in
            (self?.dictation.state ?? .idle) != .idle
        }
        hotkeys.onHoldBegan = { [weak self] in self?.dictation.startDictation() }
        hotkeys.onHoldEnded = { [weak self] in self?.dictation.stopDictation() }
        hotkeys.onCancel = { [weak self] in self?.dictation.cancelDictation() }
        dictation.hotkeyStillHeld = { [weak self] in self?.hotkeys.isKeyCurrentlyDown ?? false }

        if Permissions.accessibilityGranted, hotkeys.start() {
            NSLog("Dhwani: event tap armed at launch")
            return
        }
        NSLog("Dhwani: waiting for Accessibility (granted=\(Permissions.accessibilityGranted)) — polling")
        // Poll until the user grants Accessibility, then arm the tap.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, Permissions.accessibilityGranted else { return }
            if self.hotkeys.start() {
                NSLog("Dhwani: Accessibility granted — event tap armed")
                timer.invalidate()
                self.accessibilityRetryTimer = nil
                HUD.shared.show(.info("Dhwani armed — hold \(Settings.shared.holdKey.shortName) to dictate"))
                HUD.shared.hide(after: 2.5)
            } else {
                NSLog("Dhwani: Accessibility reported granted but tap creation failed — will retry")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityRetryTimer = timer
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Dhwani")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshIcon(for state: DictationController.State) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            switch state {
            case .idle:
                button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Dhwani")
                button.contentTintColor = nil
            case .recording:
                button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recording")
                button.contentTintColor = .systemRed
            case .processing:
                button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Processing")
                button.contentTintColor = .systemOrange
            }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Permission problems go first and loud — a dead hotkey must never be silent.
        if !Permissions.accessibilityGranted {
            let item = NSMenuItem(title: "⚠️ Accessibility needed — click to grant",
                                  action: #selector(grantAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if Permissions.micStatus != .authorized {
            let item = NSMenuItem(title: "⚠️ Microphone needed — click to grant",
                                  action: #selector(grantMicrophone), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !Permissions.accessibilityGranted || Permissions.micStatus != .authorized {
            menu.addItem(.separator())
        }

        let today = HistoryStore.shared.todayStats()
        let total = HistoryStore.shared.totalStats()

        menu.addItem(disabled("Hold \(Settings.shared.holdKey.shortName) to dictate · Esc to cancel"))
        menu.addItem(disabled("Today: \(today.words) words · \(today.notes) notes"))
        menu.addItem(disabled("All time: \(total.words) words · \(total.notes) notes"))
        menu.addItem(.separator())

        let recents = HistoryStore.shared.recent(limit: 8)
        if !recents.isEmpty {
            let recentMenu = NSMenu()
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            for entry in recents {
                let preview = entry.text.count > 56 ? String(entry.text.prefix(56)) + "…" : entry.text
                let item = NSMenuItem(title: "\(timeFormatter.string(from: entry.date))  \(preview)",
                                      action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = "Click to copy the full transcript"
                recentMenu.addItem(item)
            }
            let recentRoot = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            recentRoot.submenu = recentMenu
            menu.addItem(recentRoot)
        }

        let folderItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscripts), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
        menu.addItem(.separator())

        // Hotkey picker
        let hotkeyMenu = NSMenu()
        for key in HoldKey.allCases {
            let item = NSMenuItem(title: key.displayName, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = Settings.shared.holdKey == key ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyRoot = NSMenuItem(title: "Dictation Key", action: nil, keyEquivalent: "")
        hotkeyRoot.submenu = hotkeyMenu
        menu.addItem(hotkeyRoot)

        // Insert mode picker
        let insertMenu = NSMenu()
        let pasteItem = NSMenuItem(title: "Paste (fast, recommended)", action: #selector(selectInsertMode(_:)), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.representedObject = InsertMode.paste.rawValue
        pasteItem.state = Settings.shared.insertMode == .paste ? .on : .off
        insertMenu.addItem(pasteItem)
        let typeItem = NSMenuItem(title: "Type keystrokes (max compatibility)", action: #selector(selectInsertMode(_:)), keyEquivalent: "")
        typeItem.target = self
        typeItem.representedObject = InsertMode.type.rawValue
        typeItem.state = Settings.shared.insertMode == .type ? .on : .off
        insertMenu.addItem(typeItem)
        let insertRoot = NSMenuItem(title: "Insert Method", action: nil, keyEquivalent: "")
        insertRoot.submenu = insertMenu
        menu.addItem(insertRoot)

        let polishItem = NSMenuItem(title: "AI Polish (on-device)", action: #selector(togglePolish), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = Settings.shared.aiPolish ? .on : .off
        if !AIFormatter.isAvailable {
            polishItem.action = nil
            polishItem.toolTip = "Apple Intelligence isn't available on this Mac"
        }
        menu.addItem(polishItem)

        let liveTextItem = NSMenuItem(title: "Show Live Transcript in Pill", action: #selector(toggleLiveText), keyEquivalent: "")
        liveTextItem.target = self
        liveTextItem.state = Settings.shared.showLiveText ? .on : .off
        menu.addItem(liveTextItem)

        let soundsItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        soundsItem.target = self
        soundsItem.state = Settings.shared.playSounds ? .on : .off
        menu.addItem(soundsItem)

        let clipboardItem = NSMenuItem(title: "Restore Clipboard After Paste", action: #selector(toggleRestoreClipboard), keyEquivalent: "")
        clipboardItem.target = self
        clipboardItem.state = Settings.shared.restoreClipboard ? .on : .off
        menu.addItem(clipboardItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let permissionsItem = NSMenuItem(title: "Permissions & Setup…", action: #selector(showOnboarding), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let quitItem = NSMenuItem(title: "Quit Dhwani", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func grantAccessibility() {
        Permissions.promptAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func grantMicrophone() {
        if Permissions.micStatus == .notDetermined {
            Permissions.requestMic { _ in }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func openTranscripts() {
        NSWorkspace.shared.open(HistoryStore.transcriptsFolder)
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = HoldKey(rawValue: raw) else { return }
        Settings.shared.holdKey = key
        if key == .fn { warnAboutGlobeKeyIfNeeded() }
    }

    @objc private func selectInsertMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = InsertMode(rawValue: raw) else { return }
        Settings.shared.insertMode = mode
    }

    @objc private func togglePolish() { Settings.shared.aiPolish.toggle() }
    @objc private func toggleLiveText() { Settings.shared.showLiveText.toggle() }
    @objc private func toggleSounds() { Settings.shared.playSounds.toggle() }
    @objc private func toggleRestoreClipboard() { Settings.shared.restoreClipboard.toggle() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: move Dhwani.app into /Applications first."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Onboarding

    private func onboardIfNeeded() {
        // Auto-show only on first run or when Accessibility (the app's core
        // requirement) is missing. A denied microphone shouldn't nag on every
        // launch — dictation attempts surface that with a HUD instead.
        guard !Settings.shared.hasOnboarded || !Permissions.accessibilityGranted else { return }
        showOnboarding()
        Settings.shared.hasOnboarded = true
    }

    @objc private func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set up Dhwani"
        alert.informativeText = """
        Dhwani turns speech into text in any app: hold \(Settings.shared.holdKey.shortName), talk, release. \
        Everything runs on this Mac — no audio ever leaves it.

        It needs two permissions:

        1. Accessibility — to see the dictation key and paste text for you. \
        Status: \(Permissions.accessibilityGranted ? "✅ granted" : "❌ not granted")

        2. Microphone — to hear you. \
        Status: \(Permissions.micStatus == .authorized ? "✅ granted" : "❌ not granted")

        Tip: if pressing Fn opens the emoji picker, set System Settings → Keyboard → \
        “Press 🌐 key to” → “Do Nothing” (the button below does it for you; \
        you may need to log out and back in).
        """
        alert.addButton(withTitle: "Grant Accessibility…")
        alert.addButton(withTitle: "Enable Microphone")
        alert.addButton(withTitle: "Fix 🌐 Key Setting")
        alert.addButton(withTitle: "Done")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Permissions.promptAccessibility()
            Permissions.openAccessibilitySettings()
        case .alertSecondButtonReturn:
            Permissions.requestMic { _ in }
        case .alertThirdButtonReturn:
            setGlobeKeyToDoNothing()
        default:
            break
        }
    }

    private func warnAboutGlobeKeyIfNeeded() {
        // If the globe key is set to open Character Viewer / change input source,
        // releasing Fn after dictation triggers that too.
        let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        if usage != 0 { showOnboarding() }
    }

    private func setGlobeKeyToDoNothing() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
        try? process.run()
    }
}
