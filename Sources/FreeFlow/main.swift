import AppKit

let app = NSApplication.shared

if #available(macOS 26.0, *) {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    app.setActivationPolicy(.regular)
    let alert = NSAlert()
    alert.messageText = "FreeFlow requires macOS 26 or later"
    alert.informativeText = "FreeFlow uses Apple's on-device SpeechAnalyzer engine, which is available starting with macOS 26 (Tahoe)."
    alert.runModal()
}
