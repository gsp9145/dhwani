import AppKit
import CoreGraphics

/// Global push-to-talk key handling via a CGEventTap (requires Accessibility).
/// Modifier hotkeys (Fn, Right ⌘, Right ⌥) are observed through flagsChanged;
/// regular hotkeys (F1) are swallowed on keyDown/keyUp.
final class HotkeyManager {
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Should return true while a dictation is in flight (starting or recording).
    var isRecording: (() -> Bool)?

    static let minimumHold: TimeInterval = 0.2
    private static let escapeKeyCode: Int64 = 53

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyIsDown = false
    private var downAt: Date?

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                place: .headInsertEventTap,
                                options: .defaultTap,
                                eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall or when secure input starts; re-arm.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let hotkey = Settings.shared.holdKey
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let recording = isRecording?() ?? false

        // Escape cancels an in-flight dictation and never reaches the frontmost app.
        if recording, type == .keyDown, keyCode == Self.escapeKeyCode {
            keyIsDown = false
            DispatchQueue.main.async { self.onCancel?() }
            return nil
        }

        if hotkey.isModifier {
            if type == .flagsChanged, keyCode == hotkey.keyCode, let flag = hotkey.flag {
                let isDown = event.flags.contains(flag)
                if isDown, !keyIsDown {
                    keyIsDown = true
                    downAt = Date()
                    DispatchQueue.main.async { self.onHoldBegan?() }
                } else if !isDown, keyIsDown {
                    keyIsDown = false
                    let held = -(downAt?.timeIntervalSinceNow ?? 0)
                    DispatchQueue.main.async {
                        if held < Self.minimumHold {
                            self.onCancel?()
                        } else {
                            self.onHoldEnded?()
                        }
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            // Another key pressed while holding the modifier: the user wanted a
            // shortcut (Fn+arrow, ⌘+c, …), not dictation. Cancel and pass it through.
            if keyIsDown, recording, type == .keyDown {
                keyIsDown = false
                downAt = nil
                DispatchQueue.main.async { self.onCancel?() }
                return Unmanaged.passUnretained(event)
            }
        } else if keyCode == hotkey.keyCode {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat, !keyIsDown {
                keyIsDown = true
                downAt = Date()
                DispatchQueue.main.async { self.onHoldBegan?() }
            } else if type == .keyUp, keyIsDown {
                keyIsDown = false
                let held = -(downAt?.timeIntervalSinceNow ?? 0)
                DispatchQueue.main.async {
                    if held < Self.minimumHold {
                        self.onCancel?()
                    } else {
                        self.onHoldEnded?()
                    }
                }
            }
            // Swallow the hotkey so it doesn't reach the frontmost app.
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
