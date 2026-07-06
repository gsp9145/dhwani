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
            // Synthetic keystrokes are blocked during secure input (password
            // fields, Terminal's "Secure Keyboard Entry"). Leave the text on
            // the clipboard so nothing is lost, and report who's blocking.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .secureInputBlocked(culprit: SecureInput.culprit())
        }

        switch Settings.shared.insertMode {
        case .paste: paste(text)
        case .type: type(text)
        }
        return .inserted
    }

    private static func paste(_ text: String) {
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
            postCommandV()
        }

        guard Settings.shared.restoreClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Don't clobber anything the user copied in the meantime.
            guard pb.changeCount == ourChangeCount else { return }
            pb.clearContents()
            if !saved.isEmpty {
                pb.writeObjects(saved)
            }
        }
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
