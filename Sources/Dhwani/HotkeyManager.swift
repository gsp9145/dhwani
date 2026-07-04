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
    /// Fired when a lone quick tap expires — an accidental press, not a gesture.
    var onTapTimeout: (() -> Void)?
    /// Should return true while a dictation is in flight (recording or processing).
    var isRecording: (() -> Bool)?

    var isKeyCurrentlyDown: Bool { keyIsDown }
    private(set) var isHandsFree = false

    static let minimumHold: TimeInterval = 0.2
    /// Max gap between first tap's release and second tap's press to lock hands-free.
    static let doubleTapWindow: TimeInterval = 0.4
    private static let escapeKeyCode: Int64 = 53
    /// On Fn/Globe release macOS synthesizes a keyDown/keyUp with this code
    /// (its internal emoji-palette trigger). It's the same physical key, not a
    /// stray press — treat it as part of the Fn gesture.
    private static let globeEchoKeyCode: Int64 = 179

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
    /// The press after a quick tap: a quick release locks hands-free, but a
    /// long hold means the user is just dictating (tap-then-hold ≠ double-tap).
    private var inSecondTap = false
    /// Consume the key-up of the tap that stopped hands-free.
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
            DebugLog.log("gesture: tap while hands-free → stop & insert")
            isHandsFree = false
            gestureKey = nil
            swallowNextRelease = true
            onHoldEnded?()
            return
        }
        if doubleTapTimer != nil {
            DebugLog.log("gesture: second press inside double-tap window")
            // Second press inside the window; recording has been running since
            // the first tap's key-down. Whether this locks hands-free is
            // decided on its release: quick tap = lock, long hold = the user
            // is just dictating.
            doubleTapTimer?.invalidate()
            doubleTapTimer = nil
            inSecondTap = true
            downAt = Date()
            return
        }
        gestureKey = key
        downAt = Date()
        DebugLog.log("gesture: key down → hold began (\(key.rawValue))")
        onHoldBegan?()
    }

    private func hotkeyUp() {
        keyIsDown = false
        if swallowNextRelease {
            swallowNextRelease = false
            DebugLog.log("gesture: key up (swallowed)")
            return
        }
        let held = -(downAt?.timeIntervalSinceNow ?? 0)

        if inSecondTap {
            inSecondTap = false
            downAt = nil
            if held < Self.minimumHold {
                // Genuine double-tap: lock hands-free, keep recording.
                DebugLog.log("gesture: double-tap complete (\(Int(held * 1000))ms) → hands-free locked")
                isHandsFree = true
                onHandsFreeLocked?()
            } else {
                // Tap-then-hold: an ordinary dictation — insert on release.
                DebugLog.log("gesture: tap-then-hold release (\(Int(held * 1000))ms) → insert")
                gestureKey = nil
                onHoldEnded?()
            }
            return
        }
        downAt = nil

        if held < Self.minimumHold {
            // Might be the first half of a double-tap: keep recording and wait.
            DebugLog.log("gesture: quick tap (\(Int(held * 1000))ms) → double-tap window open")
            doubleTapTimer?.invalidate()
            let timer = Timer(timeInterval: Self.doubleTapWindow, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.doubleTapTimer = nil
                self.gestureKey = nil
                DebugLog.log("gesture: double-tap window expired → accidental tap")
                self.onTapTimeout?() // lone quick tap — accidental press
            }
            RunLoop.main.add(timer, forMode: .common)
            doubleTapTimer = timer
        } else {
            DebugLog.log("gesture: hold release (\(Int(held * 1000))ms) → insert")
            gestureKey = nil
            onHoldEnded?()
        }
    }

    private func resetGesture() {
        doubleTapTimer?.invalidate()
        doubleTapTimer = nil
        isHandsFree = false
        inSecondTap = false
        swallowNextRelease = false
        keyIsDown = false
        downAt = nil
        gestureKey = nil
    }

    /// Reset gesture state so push-to-talk can't get stuck recording after the
    /// tap missed a key-up (sleep, secure input, tap timeout).
    private func recoverFromStall() {
        DebugLog.log("tap: disabled by system — re-enabled, gesture state reset")
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

        // The Globe echo is our own hotkey talking, never a stray press.
        // Swallowing it also stops the system emoji palette from opening.
        if keyCode == Self.globeEchoKeyCode {
            if hotkey == .fn {
                return nil
            }
            // Fn isn't our hotkey: the user really pressed Globe — let the
            // system have it, but never treat it as a dictation-canceling key.
            return Unmanaged.passUnretained(event)
        }

        // Escape cancels an in-flight dictation (recording OR processing) and
        // never reaches the frontmost app.
        if recording, type == .keyDown, keyCode == Self.escapeKeyCode {
            DebugLog.log("gesture: Escape → cancel")
            resetGesture()
            onCancel?()
            return nil
        }

        // Phantom-event catcher: any key activity during a dictation is logged
        // so ghost cancels can be traced to their source.
        if recording, type == .keyDown {
            DebugLog.log("event: keyDown code=\(keyCode) during dictation (keyIsDown=\(keyIsDown) window=\(doubleTapTimer != nil) handsFree=\(isHandsFree))")
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
                DebugLog.log("gesture: stray keyDown code=\(keyCode) during hold/window → cancel")
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
