import AppKit
import Carbon.HIToolbox
import IOKit

/// Secure event input: while any process holds it (password fields, Terminal's
/// "Secure Keyboard Entry"), synthetic keystrokes are blocked system-wide.
enum SecureInput {
    static var isActive: Bool { IsSecureEventInputEnabled() }

    /// The app holding secure input, when the system exposes it. Background
    /// enablers can be misreported (rdar://48953777) — treat as a hint.
    static func culprit() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
                service, "kCGSSessionSecureInputPID" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? Int,
              value > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(value))?.localizedName
    }
}
