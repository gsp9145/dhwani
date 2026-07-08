import AppKit

/// A floating panel that previews a full transcript to the LEFT of the Recent
/// submenu while an item is hovered. Native NSMenuItem tooltips can't be
/// positioned and end up overlapping the menu; this replaces them.
@MainActor
final class MenuPreviewPanel {
    static let shared = MenuPreviewPanel()

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    private static let width: CGFloat = 320
    private static let pad: CGFloat = 14
    private static let maxHeight: CGFloat = 420

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Self.pad),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Self.pad),
            label.topAnchor.constraint(equalTo: effect.topAnchor, constant: Self.pad),
            label.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Self.pad),
        ])
        panel.contentView = effect
    }

    func show(text: String, beside itemView: NSView) {
        hideWork?.cancel()
        guard let menuWindow = itemView.window,
              let screen = menuWindow.screen ?? NSScreen.main else { return }

        let preview = text.count > 1200 ? String(text.prefix(1200)) + "…" : text
        label.stringValue = preview

        let innerWidth = Self.width - Self.pad * 2
        let textHeight = (preview as NSString).boundingRect(
            with: NSSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font as Any]).height
        let height = min(Self.maxHeight, ceil(textHeight) + Self.pad * 2)

        // Prefer the left of the menu; flip right only if it would clip.
        var x = menuWindow.frame.minX - Self.width - 6
        if x < screen.visibleFrame.minX + 4 {
            x = menuWindow.frame.maxX + 6
        }

        // Align the panel's top with the hovered row's top.
        let rowInWindow = itemView.convert(itemView.bounds, to: nil)
        let rowOnScreen = menuWindow.convertToScreen(rowInWindow)
        var y = rowOnScreen.maxY - height
        y = max(screen.visibleFrame.minY + 4, min(y, screen.visibleFrame.maxY - height - 4))

        panel.setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    /// Hide after a short delay so moving between rows doesn't flicker.
    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func hideNow() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

/// Custom Recent-menu row: draws like a menu item, previews the full transcript
/// on hover (to the left of the menu), copies on click.
@MainActor
final class RecentMenuItemView: NSView {
    private let displayLabel: String
    private let fullText: String
    private let onCopy: (String) -> Void
    private var highlighted = false
    private var tracking: NSTrackingArea?

    private static let height: CGFloat = 22
    private static let width: CGFloat = 360
    private static let leading: CGFloat = 14

    init(label: String, fullText: String, onCopy: @escaping (String) -> Void) {
        self.displayLabel = label
        self.fullText = fullText
        self.onCopy = onCopy
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let textRect = NSRect(x: Self.leading, y: 2,
                              width: bounds.width - Self.leading - 8, height: bounds.height - 4)
        (displayLabel as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func mouseEntered(with event: NSEvent) {
        highlighted = true
        needsDisplay = true
        MenuPreviewPanel.shared.show(text: fullText, beside: self)
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = false
        needsDisplay = true
        MenuPreviewPanel.shared.scheduleHide()
    }

    override func mouseUp(with event: NSEvent) {
        MenuPreviewPanel.shared.hideNow()
        enclosingMenuItem?.menu?.cancelTracking()
        onCopy(fullText)
    }
}
