import AppKit
import ServiceManagement
import SwiftUI

@available(macOS 26.0, *)
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let dictation = DictationController()
    private var accessibilityRetryTimer: Timer?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy would double-paste every dictation.
        // Newest wins — ask older instances to quit (they may be mid-shutdown
        // from an update/reinstall; self-terminating here would leave the
        // stale build running).
        if let bundleID = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .forEach { $0.terminate() }
        }
        setupStatusItem()
        setupDictation()
        startHotkeysWhenTrusted()
        dictation.prepare()
        UpdateChecker.beginAutomaticChecks { [weak self] in
            self?.dictation.state == .idle
        }
        // The setup dialog is modal — show it only after everything above is
        // armed, so the hotkey, model download, and updates aren't hostage to
        // the user reading a dialog.
        DispatchQueue.main.async { [weak self] in
            self?.onboardIfNeeded()
        }
    }

    /// Don't lose a dictation that's mid-finalize: give the pipeline a moment
    /// to insert before quitting (auto-update restarts pass through here too).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard dictation.state == .processing else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        hotkeys.onHoldEnded = { [weak self] polish in self?.dictation.stopDictation(polishModifier: polish) }
        hotkeys.onPolishArm = { armed in HUD.shared.setPolishArmed(armed) }
        hotkeys.onCancel = { [weak self] in self?.dictation.cancelDictation() }
        hotkeys.onHandsFreeLocked = { [weak self] in self?.dictation.lockHandsFree() }
        hotkeys.onTapTimeout = { [weak self] in self?.dictation.dismissAccidentalTap() }
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

    /// The ध brand glyph. With no color it's a template image (adapts to the
    /// menu bar's appearance); with a color it's pre-rendered in that color —
    /// contentTintColor doesn't reliably tint custom template images on
    /// status-bar buttons, so state colors are baked in instead.
    private static func glyphIcon(color: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let font = NSFont(name: "KohinoorDevanagari-Semibold", size: 15)
                ?? NSFont.systemFont(ofSize: 15, weight: .semibold)
            let glyph = NSAttributedString(string: "ध", attributes: [
                .font: font,
                .foregroundColor: color ?? NSColor.black,
            ])
            let bounds = glyph.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
            glyph.draw(at: NSPoint(x: (rect.width - bounds.width) / 2 - bounds.minX,
                                   y: (rect.height - bounds.height) / 2 - bounds.minY))
            return true
        }
        image.isTemplate = (color == nil)
        return image
    }

    private static let idleIcon = glyphIcon(color: nil)
    private static let recordingIcon = glyphIcon(color: .systemRed)
    private static let processingIcon = glyphIcon(color: .systemOrange)

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.idleIcon
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshIcon(for state: DictationController.State) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            switch state {
            case .idle: button.image = Self.idleIcon
            case .recording: button.image = Self.recordingIcon
            case .processing: button.image = Self.processingIcon
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

        menu.addItem(disabled("Hold \(Settings.shared.holdKey.shortName) to dictate · double-tap for hands-free · Esc cancels"))
        menu.addItem(disabled("Hold ⌥ at release to \(Settings.shared.aiPolish ? "skip" : "apply") AI polish for one dictation"))
        menu.addItem(disabled("Today: \(today.words) words · \(today.notes) notes"))
        menu.addItem(disabled("All time: \(total.words) words · \(total.notes) notes"))
        menu.addItem(.separator())

        let recents = HistoryStore.shared.recent(limit: 8)
        if !recents.isEmpty {
            let recentMenu = NSMenu()
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            for entry in recents {
                let preview = entry.text.count > 48 ? String(entry.text.prefix(48)) + "…" : entry.text
                let item = NSMenuItem(title: "\(timeFormatter.string(from: entry.date)) · \(entry.appName)  \(preview)",
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

        menu.addItem(.separator())
        menu.addItem(disabled("Dhwani v\(UpdateChecker.currentVersion)"))

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Dhwani", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Dhwani Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

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
