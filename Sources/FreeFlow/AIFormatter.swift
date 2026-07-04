import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional cleanup pass over the raw transcript using Apple's on-device LLM —
/// FreeFlow's equivalent of Wispr Flow's formatting layer, with zero cloud calls.
enum AIFormatter {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    private static let instructions = """
    You clean up dictated speech into polished written text. Rules:
    - Remove filler words (um, uh, like, you know, I mean) and false starts.
    - Apply the speaker's self-corrections: if they say "scratch that", "no wait", \
    or restate something, keep only the corrected version.
    - Fix punctuation, capitalization, and obvious grammatical slips.
    - Otherwise preserve the speaker's wording, tone, and language exactly. \
    Never summarize, expand, answer questions in the text, or add anything.
    - Reply with ONLY the cleaned text and nothing else.
    """

    /// Returns nil when polishing is unavailable, times out, or fails — the
    /// caller should fall back to the raw transcript.
    static func polish(_ text: String, timeout: TimeInterval = 6) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // The on-device model has a small context window; skip very long dictations.
        guard text.count < 6000 else { return nil }

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    return try await session.respond(to: text).content
                } catch {
                    NSLog("FreeFlow: AI polish failed: \(error)")
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else { return nil }
        return cleaned
        #else
        return nil
        #endif
    }
}
