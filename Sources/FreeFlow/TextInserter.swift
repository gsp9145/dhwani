import AppKit
import Carbon.HIToolbox

/// Inserts text into the frontmost app, Wispr-style: put it on the pasteboard,
/// synthesize ⌘V, then restore the user's clipboard.
enum TextInserter {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let vKeyCode: CGKeyCode = 9

    /// Returns false if the text could only be left on the clipboard
    /// (e.g. a secure input field is active).
    @discardableResult
    static func insert(_ text: String) -> Bool {
        if IsSecureEventInputEnabled() {
            // Synthetic keystrokes are blocked during secure input (password
            // fields). Leave the text on the clipboard so nothing is lost.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            return false
        }

        switch Settings.shared.insertMode {
        case .paste: paste(text)
        case .type: type(text)
        }
        return true
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

        postCommandV()

        guard Settings.shared.restoreClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
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
        up?.post(tap: .cghidEventTap)
    }

    /// Fallback for apps where synthetic paste misbehaves: type the text as
    /// unicode keyboard events in small chunks.
    private static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let units = Array(text.utf16)
        var index = 0
        let chunkSize = 20
        while index < units.count {
            let chunk = Array(units[index..<min(index + chunkSize, units.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.post(tap: .cghidEventTap)
            index += chunkSize
            usleep(3000)
        }
    }
}
