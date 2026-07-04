import AppKit

/// The Wispr-style pill at the bottom of the screen. Non-activating, so focus
/// never leaves the app being dictated into.
final class HUD {
    static let shared = HUD()

    enum State {
        case listening(String)
        case processing
        case done(words: Int)
        case error(String)
        case info(String)
    }

    private let panel: NSPanel
    private let dot = NSTextField(labelWithString: "●")
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private static let width: CGFloat = 560
    private static let height: CGFloat = 44

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.height / 2
        effect.layer?.masksToBounds = true

        dot.frame = NSRect(x: 20, y: (Self.height - 20) / 2, width: 16, height: 20)
        dot.font = .systemFont(ofSize: 12)
        dot.textColor = .systemRed
        dot.alignment = .center

        label.frame = NSRect(x: 44, y: (Self.height - 20) / 2, width: Self.width - 64, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead // show the tail of the live transcript
        label.maximumNumberOfLines = 1

        effect.addSubview(dot)
        effect.addSubview(label)
        panel.contentView = effect
    }

    func show(_ state: State) {
        DispatchQueue.main.async { self.apply(state) }
    }

    func update(text: String) {
        DispatchQueue.main.async {
            guard self.panel.isVisible else { return }
            if !text.isEmpty { self.label.stringValue = text }
        }
    }

    func hide(after delay: TimeInterval = 0) {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            if delay <= 0 {
                self.orderOut()
                return
            }
            self.hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.orderOut()
            }
        }
    }

    private func apply(_ state: State) {
        hideTimer?.invalidate()
        switch state {
        case .listening(let text):
            dot.textColor = .systemRed
            dot.stringValue = "●"
            label.stringValue = text.isEmpty ? "Listening…" : text
        case .processing:
            dot.textColor = .systemOrange
            dot.stringValue = "◐"
            label.stringValue = "Polishing…"
        case .done(let words):
            dot.textColor = .systemGreen
            dot.stringValue = "✓"
            label.stringValue = "Inserted \(words) word\(words == 1 ? "" : "s")"
        case .error(let message):
            dot.textColor = .systemYellow
            dot.stringValue = "!"
            label.stringValue = message
        case .info(let message):
            dot.textColor = .systemBlue
            dot.stringValue = "●"
            label.stringValue = message
        }
        position()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - Self.width / 2
        let y = frame.minY + 20
        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: Self.height), display: true)
    }

    private func orderOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }
}
