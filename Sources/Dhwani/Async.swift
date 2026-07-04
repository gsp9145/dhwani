import Foundation
import os

/// Runs `operation` with a deadline. Returns nil on timeout; the operation's
/// task is cancelled, though a non-cooperative operation may still finish in
/// the background (its result is then discarded).
func withTimeout<T: Sendable>(seconds: TimeInterval,
                              _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        func claimResume() -> Bool {
            resumed.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
        }
        let work = Task {
            let value = await operation()
            if claimResume() { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if claimResume() {
                work.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}
