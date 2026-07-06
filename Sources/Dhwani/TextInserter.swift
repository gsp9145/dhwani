import AppKit
import Carbon.HIToolbox

enum InsertOutcome {
    case inserted
    /// Secure input blocked synthetic keystrokes; text was left on the clipboard.
    case secureInputBlocked(culprit: String?)
}

/// Inserts text into the frontmost app, Wispr-style: put it on the pasteboard,
/// synthesize ⌘V, then restore the user's clipboard.
enum TextInserter {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let vKeyCode: CGKeyCode = 9

    @discardableResult
    static func insert(_ text: String) -> InsertOutcome {
        if SecureInput.isActive {
            // Synthetic keystrokes are blocked during secure input. Two cases:
            // a real password field (never paste, never persist) vs an app
            // like Terminal holding "Secure Keyboard Entry" for everything it
            // does. For the latter, keystrokes are blocked but Accessibility
            // MENU actions aren't — paste by pressing the app's own
            // Edit ▸ Paste item.
            if focusedElementIsSecureField() {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                return .secureInputBlocked(culprit: nil)
            }
            if paste(text, via: .menuAction) {
                return .inserted
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .secureInputBlocked(culprit: SecureInput.culprit())
        }

        switch Settings.shared.insertMode {
        case .paste: _ = paste(text, via: .keystroke)
        case .type: type(text)
        }
        return .inserted
    }

    /// Is the focused UI element an actual password box?
    private static func focusedElementIsSecureField() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &roleRef)
        return (roleRef as? String) == "AXSecureTextField"
    }

    /// Find the frontmost app's plain-⌘V menu item (Paste, in any language).
    private static func pasteMenuItem(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarObj = menuBarRef, CFGetTypeID(menuBarObj) == AXUIElementGetTypeID() else { return nil }
        let menuBar = menuBarObj as! AXUIElement
        for top in children(of: menuBar) {
            for menu in children(of: top) {
                for item in children(of: menu) {
                    var charRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &charRef) == .success,
                          (charRef as? String) == "V" else { continue }
                    var modRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modRef)
                    if (modRef as? Int ?? -1) == 0 { // plain ⌘V, no extra modifiers
                        return item
                    }
                }
            }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AnyObject] else { return [] }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    private enum PasteMechanism {
        case keystroke  // synthetic ⌘V — fast, universal, blocked by secure input
        case menuAction // AX press on the app's Paste menu item — survives secure input
    }

    /// Returns false only for .menuAction when no Paste item could be pressed.
    private static func paste(_ text: String, via mechanism: PasteMechanism) -> Bool {
        // For menu actions, resolve the target before touching the clipboard.
        var menuItem: AXUIElement?
        if case .menuAction = mechanism {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let item = pasteMenuItem(for: pid) else { return false }
            menuItem = item
        }

        let pb = NSPasteboard.general

        var saved: [NSPasteboardItem] = []
        if Settings.shared.restoreClipboard {
            for item in pb.pasteboardItems ?? [] {
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                saved.append(copy)
            }
        }

        pb.declareTypes([.string, transientType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transientType) // clipboard managers skip transient items
        let ourChangeCount = pb.changeCount

        // Give the pasteboard server a moment to settle before the app reads it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            switch mechanism {
            case .keystroke:
                postCommandV()
            case .menuAction:
                if let menuItem {
                    let result = AXUIElementPerformAction(menuItem, kAXPressAction as CFString)
                    DebugLog.log("insert: menu-action paste \(result == .success ? "pressed" : "failed (\(result.rawValue))")")
                }
            }
        }

        if Settings.shared.restoreClipboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // Don't clobber anything the user copied in the meantime.
                guard pb.changeCount == ourChangeCount else { return }
                pb.clearContents()
                if !saved.isEmpty {
                    pb.writeObjects(saved)
                }
            }
        }
        return true
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(10_000) // some apps drop the paste if down/up land in the same instant
        up?.post(tap: .cghidEventTap)
    }

    /// Fallback for apps where synthetic paste misbehaves: type the text as
    /// unicode keyboard events. Runs off the main thread — the usleep pacing
    /// would otherwise stall the event tap that lives on the main run loop.
    /// Chunks split on character boundaries so surrogate pairs (emoji) are
    /// never torn across two events.
    private static func type(_ text: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            let maxUnits = 20 // keyboardSetUnicodeString truncates beyond this
            var chunk: [UInt16] = []

            func flush() {
                guard !chunk.isEmpty else { return }
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                up?.post(tap: .cghidEventTap)
                chunk.removeAll(keepingCapacity: true)
                usleep(3000)
            }

            for character in text {
                let units = Array(String(character).utf16)
                if chunk.count + units.count > maxUnits { flush() }
                chunk.append(contentsOf: units)
            }
            flush()
        }
    }
}
