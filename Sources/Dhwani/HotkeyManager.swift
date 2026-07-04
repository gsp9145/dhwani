import AppKit
import CoreGraphics

/// Global dictation-key handling via a CGEventTap (requires Accessibility).
/// Gestures:
///   hold       → push-to-talk: record while held, insert on release
///   double-tap → hands-free: recording locks on; tap again to stop & insert
///   Esc        → cancel whatever is in flight
/// Modifier hotkeys (Fn, Right ⌘, Right ⌥) arrive as flagsChanged events;
/// regular hotkeys (F1) are swallowed on keyDown/keyUp.
///
/// The tap's run-loop source lives on the main run loop, so `handle` executes
/// on the main thread and callbacks are invoked synchronously.
final class HotkeyManager {
    var onHoldBegan: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fired when a double-tap locks hands-free recording.
    var onHandsFreeLocked: (() -> Void)?
    /// Should return true while a dictation is in flight (recording or processing).
    var isRecording: (() -> Bool)?

    var isKeyCurrentlyDown: Bool { keyIsDown }
    private(set) var isHandsFree = false

    static let minimumHold: TimeInterval = 0.2
    /// Max gap between first tap's release and second tap's press to lock hands-free.
    static let doubleTapWindow: TimeInterval = 0.4
    private static let escapeKeyCode: Int64 = 53

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?

    private var keyIsDown = false
    private var downAt: Date?
    /// The key that started the current gesture — events are judged against
    /// this even if the user changes the hotkey setting mid-gesture.
    private var gestureKey: HoldKey?
    /// Armed after a quick tap: recording keeps running while we wait to see
    /// whether a second tap locks hands-free; on expiry the tap was accidental.
    private var doubleTapTimer: Timer?
    /// Consume the key-up of the tap that locked or stopped hands-free.
    private var swallowNextRelease = false

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

    // MARK: - Gesture state machine

    private func hotkeyDown(_ key: HoldKey) {
        keyIsDown = true

        if isHandsFree {
            // Tap while locked = stop & insert. Its release means nothing.
            isHandsFree = false
            gestureKey = nil
            swallowNextRelease = true
            onHoldEnded?()
            return
        }
        if doubleTapTimer != nil {
            // Second tap inside the window — lock hands-free; recording has
            // been running since the first tap's key-down.
            doubleTapTimer?.invalidate()
            doubleTapTimer = nil
            isHandsFree = true
            swallowNextRelease = true
            onHandsFreeLocked?()
            return
        }
        gestureKey = key
        downAt = Date()
        onHoldBegan?()
    }

    private func hotkeyUp() {
        keyIsDown = false
        if swallowNextRelease {
            swallowNextRelease = false
            return
        }
        let held = -(downAt?.timeIntervalSinceNow ?? 0)
        downAt = nil

        if held < Self.minimumHold {
            // Might be the first half of a double-tap: keep recording and wait.
            doubleTapTimer?.invalidate()
            let timer = Timer(timeInterval: Self.doubleTapWindow, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.doubleTapTimer = nil
                self.gestureKey = nil
                self.onCancel?() // lone quick tap — accidental press
            }
            RunLoop.main.add(timer, forMode: .common)
            doubleTapTimer = timer
        } else {
            gestureKey = nil
            onHoldEnded?()
        }
    }

    private func resetGesture() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        isHandsFree = false
        swallowNextRelease = false
        keyIsDown = false
        downAt = nil
        gestureKey = nil
    }

    /// Reset gesture state so push-to-talk can't get stuck recording after the
    /// tap missed a key-up (sleep, secure input, tap timeout).
    private func recoverFromStall() {
        resetGesture()
        if isRecording?() == true {
            onCancel?()
        }
    }

    // MARK: - Event tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables taps that stall or when secure input starts; re-arm.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            recoverFromStall()
            return Unmanaged.passUnretained(event)
        }

        let hotkey = gestureKey ?? Settings.shared.holdKey
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let recording = isRecording?() ?? false

        // Escape cancels an in-flight dictation (recording OR processing) and
        // never reaches the frontmost app.
        if recording, type == .keyDown, keyCode == Self.escapeKeyCode {
            resetGesture()
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
                    hotkeyDown(hotkey)
                } else if !isDown, keyIsDown {
                    hotkeyUp()
                }
                // Swallow Fn so the system Globe action (emoji picker / input
                // source switch) never fires from a dictation press. Fn as a
                // combo modifier still works: other keys' events carry the
                // .maskSecondaryFn flag themselves.
                return hotkey == .fn ? nil : Unmanaged.passUnretained(event)
            }
            // Another key pressed while holding the modifier (or inside the
            // double-tap window): the user wanted a shortcut, not dictation.
            // Cancel and pass it through. Hands-free is exempt — typing while
            // locked-on is allowed.
            if type == .keyDown, recording, !isHandsFree, keyIsDown || doubleTapTimer != nil {
                resetGesture()
                onCancel?()
                return Unmanaged.passUnretained(event)
            }
        } else if keyCode == hotkey.keyCode {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown, !isRepeat, !keyIsDown {
                hotkeyDown(hotkey)
            } else if type == .keyUp, keyIsDown {
                hotkeyUp()
            }
            // Swallow the hotkey so it doesn't reach the frontmost app.
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
