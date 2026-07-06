import Carbon.HIToolbox
import CoreGraphics

/// Virtual keycodes are positional: kVK_ANSI_V (9) is a physical key, not the
/// letter V. On Dvorak and friends that position types something else, and a
/// synthetic ⌘V built on it presses the wrong shortcut. Resolve the actual
/// keycode for a character from the live keyboard layout.
enum KeyboardLayout {
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code: UInt16 in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let error = UCKeyTranslate(layout,
                                           code,
                                           UInt16(kUCKeyActionDisplay),
                                           0, // no modifiers
                                           UInt32(LMGetKbdType()),
                                           UInt32(kUCKeyTranslateNoDeadKeysBit),
                                           &deadKeyState,
                                           chars.count,
                                           &length,
                                           &chars)
                if error == noErr, length == 1,
                   let scalar = Unicode.Scalar(chars[0]),
                   Character(scalar) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
