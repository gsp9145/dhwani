import Foundation
import CoreGraphics

enum HoldKey: String, CaseIterable {
    case fn
    case rightCommand
    case rightOption
    case f1

    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .f1: return 122
        }
    }

    /// Modifier keys arrive as flagsChanged events; regular keys as keyDown/keyUp.
    var isModifier: Bool { self != .f1 }

    var flag: CGEventFlags? {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .f1: return nil
        }
    }

    /// Device-specific flag bit (IOLLEvent.h NX_DEVICE…KEYMASK). The coarse
    /// CGEventFlags masks are side-agnostic — holding LEFT ⌘ would mask the
    /// release of RIGHT ⌘ and leave recording stuck on without these.
    var deviceBit: UInt64? {
        switch self {
        case .rightCommand: return 0x0010 // NX_DEVICERCMDKEYMASK
        case .rightOption: return 0x0040  // NX_DEVICERALTKEYMASK
        case .fn, .f1: return nil
        }
    }

    var displayName: String {
        switch self {
        case .fn: return "Fn / Globe 🌐"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f1: return "F1 (needs “F1, F2… as standard function keys”)"
        }
    }

    var shortName: String {
        switch self {
        case .fn: return "Fn"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f1: return "F1"
        }
    }
}

enum InsertMode: String {
    case paste
    case type
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private init() {}

    var holdKey: HoldKey {
        get { HoldKey(rawValue: defaults.string(forKey: "holdKey") ?? "") ?? .fn }
        set { defaults.set(newValue.rawValue, forKey: "holdKey") }
    }

    var insertMode: InsertMode {
        get { InsertMode(rawValue: defaults.string(forKey: "insertMode") ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: "insertMode") }
    }

    var aiPolish: Bool {
        get { defaults.bool(forKey: "aiPolish") }
        set { defaults.set(newValue, forKey: "aiPolish") }
    }

    var playSounds: Bool {
        get { defaults.object(forKey: "playSounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    var restoreClipboard: Bool {
        get { defaults.object(forKey: "restoreClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "restoreClipboard") }
    }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }
}
