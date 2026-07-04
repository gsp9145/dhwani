import AppKit
import CoreGraphics

/// Global push-to-talk key handling via a CGEventTap (requires Accessibility).
/// Modifier hotkeys (Fn, Right ⌘, Right ⌥) are observed through flagsChanged;
/// regular hotkeys (F1) are swallowed on keyDown/keyUp.
///
/// The tap's run-loop source lives on the main run loop, so `handle` executes
/// on the main thread and callbacks are invoked synchronously — no stale-state
/// window between the event and the controller's reaction.
final class HotkeyManager {
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Should return true while a dictation is in flight (recording or processing).
    var isRecording: (() -> Bool)?

    var isKeyCurrentlyDown: Bool { keyIsDown }

    static let minimumHold: TimeInterval = 0.2
    private static let escapeKeyCode: Int64 = 53

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var keyIsDown = false
    private var downAt: Date?
    /// The key that started the current hold — the release is judged against
    /// this even if the user changes the hotkey setting mid-hold.
    private var activeHoldKey: HoldKey?

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

        // Event taps silently die after sleep/wake or system stalls; watch and revive.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                self.recoverFromStall()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        return true
    }

    /// Reset held-key state so push-to-talk can't get stuck recording after the
    /// tap missed a key-up (sleep, secure input, tap timeout).
    private func recoverFromStall() {
        endHold()
        if isRecording?() == true {
            onCancel?()
        }
    }

    private func beginHold(_ key: HoldKey) {
        keyIsDown = true
        activeHoldKey = key
        downAt = Date()
    }

    private func endHold() {
        keyIsDown = false
        activeHoldKey = nil
        downAt = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall or when secure input starts; re-arm.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            recoverFromStall()
            return Unmanaged.passUnretained(event)
        }

        let hotkey = activeHoldKey ?? Settings.shared.holdKey
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let recording = isRecording?() ?? false

        // Escape cancels an in-flight dictation (recording OR processing) and
        // never reaches the frontmost app.
        if recording, type == .keyDown, keyCode == Self.escapeKeyCode {
            endHold()
            onCancel?()
            return nil
        }

        if hotkey.isModifier {
            if type == .flagsChanged, keyCode == hotkey.keyCode {
                let isDown: Bool
                if let bit = hotkey.deviceBit {
                    // Side-specific bit: immune to the other-side key of the
                    // same pair being held simultaneously.
                    isDown = event.flags.rawValue & bit != 0
                } else if let flag = hotkey.flag {
                    isDown = event.flags.contains(flag)
                } else {
                    isDown = false
                }
                if isDown, !keyIsDown {
                    beginHold(hotkey)
                    onHoldBegan?()
                } else if !isDown, keyIsDown {
                    let held = -(downAt?.timeIntervalSinceNow ?? 0)
                    endHold()
                    if held < Self.minimumHold {
                        onCancel?()
                    } else {
                        onHoldEnded?()
                    }
                }
                // Swallow Fn so the system Globe action (emoji picker / input
                // source switch) never fires from a dictation press. Fn as a
                // combo modifier still works: other keys' events carry the
                // .maskSecondaryFn flag themselves.
                return hotkey == .fn ? nil : Unmanaged.passUnretained(event)
            }
            // Another key pressed while holding the modifier: the user wanted a
            // shortcut (Fn+arrow, ⌘+c, …), not dictation. Cancel and pass it through.
            if keyIsDown, recording, type == .keyDown {
                endHold()
                onCancel?()
                return Unmanaged.passUnretained(event)
            }
        } else if keyCode == hotkey.keyCode {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat, !keyIsDown {
                beginHold(hotkey)
                onHoldBegan?()
            } else if type == .keyUp, keyIsDown {
                let held = -(downAt?.timeIntervalSinceNow ?? 0)
                endHold()
                if held < Self.minimumHold {
                    onCancel?()
                } else {
                    onHoldEnded?()
                }
            }
            // Swallow the hotkey so it doesn't reach the frontmost app.
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
