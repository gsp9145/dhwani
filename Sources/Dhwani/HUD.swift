import AppKit

/// Wispr-style waveform bars, driven by the live microphone level.
final class WaveformView: NSView {
    /// 0…1, updated from the audio pipeline (main thread).
    var level: Float = 0
    /// Processing mode: a gentle idle pulse instead of voice-driven bars.
    var processing = false

    private let barCount = 12
    private var heights: [CGFloat]
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        heights = Array(repeating: 0.1, count: barCount)
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func start() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        phase += 0.35
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for i in 0..<barCount {
            let target: CGFloat
            if processing {
                target = 0.22 + 0.18 * abs(sin(phase * 0.45 + CGFloat(i) * 0.7))
            } else {
                // Center-weighted envelope × per-bar jitter, scaled by voice level.
                let envelope = sin(CGFloat(i) / CGFloat(barCount - 1) * .pi)
                let jitter = abs(sin(phase + CGFloat(i) * 1.9) * sin(phase * 0.63 + CGFloat(i) * 0.4))
                target = max(0.08, CGFloat(level) * envelope * (0.35 + 0.65 * jitter) + 0.05)
            }
            heights[i] = reduceMotion ? target : heights[i] * 0.55 + target * 0.45
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3.5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        var x = (bounds.width - totalWidth) / 2
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        for i in 0..<barCount {
            let h = max(3, heights[i] * bounds.height)
            let y = (bounds.height - h) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: h),
                         xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}

/// The bottom-center pill. Compact by default (just the waveform, like Wispr's
/// Flow Bar); a wider live-transcript variant when the user enables it.
/// Non-activating, so focus never leaves the app being dictated into.
final class HUD {
    static let shared = HUD()

    enum State {
        case listening
        case processing
        case done(words: Int)
        case error(String)
        case info(String)
    }

    private let panel: NSPanel
    private let effect: NSVisualEffectView
    private let wave = WaveformView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private static let pillHeight: CGFloat = 36
    private static let compactWidth: CGFloat = 130
    private static let liveWidth: CGFloat = 480
    private static let maxTextWidth: CGFloat = 560

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.compactWidth, height: Self.pillHeight),
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

        effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.compactWidth, height: Self.pillHeight))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.pillHeight / 2
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingHead // live transcript shows its tail
        label.maximumNumberOfLines = 1
        label.alignment = .center

        effect.addSubview(wave)
        effect.addSubview(label)
        panel.contentView = effect
    }

    // MARK: - Public API (safe from any thread)

    func show(_ state: State) {
        DispatchQueue.main.async { self.apply(state) }
    }

    /// Live transcript text; only rendered when the wide live-text pill is active.
    func update(text: String) {
        DispatchQueue.main.async {
            guard self.panel.isVisible, Settings.shared.showLiveText, !text.isEmpty else { return }
            self.label.stringValue = text
        }
    }

    /// Microphone level 0…1 for the waveform.
    func updateLevel(_ level: Float) {
        DispatchQueue.main.async { self.wave.level = level }
    }

    func hide(after delay: TimeInterval = 0) {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            if delay <= 0 {
                self.orderOut()
                return
            }
            // .common mode so the timer still fires while a menu is being tracked.
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                self?.orderOut()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.hideTimer = timer
        }
    }

    // MARK: - Layout

    private func apply(_ state: State) {
        hideTimer?.invalidate()
        switch state {
        case .listening:
            wave.level = 0
            wave.processing = false
            wave.start()
            if Settings.shared.showLiveText {
                label.stringValue = ""
                label.alignment = .left
                layoutLive()
            } else {
                layoutCompactWave()
            }
        case .processing:
            wave.processing = true
            wave.start()
            layoutCompactWave()
        case .done(let words):
            wave.stop()
            label.alignment = .center
            layoutText("✓ \(words) word\(words == 1 ? "" : "s")")
        case .error(let message):
            wave.stop()
            label.alignment = .center
            layoutText("⚠︎ \(message)")
        case .info(let message):
            wave.stop()
            label.alignment = .center
            layoutText(message)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func layoutCompactWave() {
        label.isHidden = true
        wave.isHidden = false
        wave.frame = NSRect(x: 0, y: 6, width: Self.compactWidth, height: Self.pillHeight - 12)
        setPanelWidth(Self.compactWidth)
    }

    private func layoutLive() {
        label.isHidden = false
        wave.isHidden = false
        wave.frame = NSRect(x: 12, y: 6, width: 78, height: Self.pillHeight - 12)
        label.frame = NSRect(x: 98, y: (Self.pillHeight - 18) / 2, width: Self.liveWidth - 118, height: 18)
        setPanelWidth(Self.liveWidth)
    }

    private func layoutText(_ text: String) {
        wave.isHidden = true
        label.isHidden = false
        label.stringValue = text
        let textWidth = (text as NSString).size(withAttributes: [.font: label.font!]).width
        let width = min(max(textWidth + 44, Self.compactWidth), Self.maxTextWidth)
        label.frame = NSRect(x: 22, y: (Self.pillHeight - 18) / 2, width: width - 44, height: 18)
        setPanelWidth(width)
    }

    private func setPanelWidth(_ width: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let rect = NSRect(x: frame.midX - width / 2,
                          y: frame.minY + 20,
                          width: width,
                          height: Self.pillHeight)
        panel.setFrame(rect, display: true)
    }

    private func orderOut() {
        wave.stop()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        })
    }
}
