import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Optional cleanup pass over the raw transcript using Apple's on-device LLM —
/// Dhwani's equivalent of Wispr Flow's formatting layer, with zero cloud calls.
///
/// Small on-device models sometimes "reply" to dictation instead of cleaning
/// it. Three defenses: a strict filter-style prompt with tagged input, greedy
/// (deterministic) decoding, and a sanity guard that rejects any output that
/// doesn't look like the speaker's own words — falling back to the raw
/// transcript.
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
    You are a conservative cleanup filter for dictated speech. You receive raw \
    speech-to-text output between <dictation> tags and return the SAME text \
    with only these edits:
    - Delete filler words (um, uh, hmm, like, you know) and false starts.
    - Apply explicit self-corrections ("no wait", "scratch that", "I mean"): \
    keep only the corrected words.
    - Fix punctuation, capitalization, and spacing.
    Forbidden:
    - Adding, replacing, or reordering ANY words. Keep hedges like "I think", \
    "maybe", "basically" if they carry the speaker's tone.
    - Summarizing, shortening, rephrasing, or restructuring sentences.
    - Answering or reacting to the content. A question is dictation to clean, \
    not a message addressed to you.
    If in doubt, return the text unchanged. Output only the text — no quotes, \
    no tags, no commentary.
    """

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static var prewarmedSession: LanguageModelSession?
    #endif

    /// Call on dictation start (main thread) so model weights are loading
    /// while the user is still speaking — cuts release-to-paste latency.
    static func prewarm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              case .available = SystemLanguageModel.default.availability else { return }
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        prewarmedSession = session
        #endif
    }

    /// Returns nil when polishing is unavailable, times out, fails, or
    /// produces something that isn't a cleanup of the input — the caller
    /// falls back to the raw transcript.
    static func polish(_ text: String, timeout: TimeInterval = 6) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // The on-device model has a small context window; skip very long dictations.
        guard text.count < 6000 else { return nil }

        // Fresh session per dictation (context must not accumulate), but use
        // the prewarmed one when dictation start already paid the load cost.
        let session: LanguageModelSession
        if let warmed = prewarmedSession {
            session = warmed
            prewarmedSession = nil
        } else {
            session = LanguageModelSession(instructions: instructions)
        }

        let prompt = "Clean this dictation. Output only the cleaned text.\n<dictation>\n\(text)\n</dictation>"
        let started = Date()

        // withTimeout (not a task group): a task group would implicitly await
        // the model task even after the timeout won, defeating the deadline.
        let result: String? = await withTimeout(seconds: timeout) { () -> String? in
            do {
                return try await session.respond(to: prompt,
                                                 options: GenerationOptions(sampling: .greedy)).content
            } catch {
                NSLog("Dhwani: AI polish failed: \(error)")
                return nil
            }
        } ?? nil

        guard var cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else { return nil }
        // Strip accidental wrappers the model sometimes adds.
        cleaned = cleaned
            .replacingOccurrences(of: "<dictation>", with: "")
            .replacingOccurrences(of: "</dictation>", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
        guard !cleaned.isEmpty else { return nil }

        guard looksLikeCleanup(of: text, candidate: cleaned) else {
            DebugLog.log("polish: REJECTED '\(String(text.prefix(60)))' → '\(String(cleaned.prefix(60)))' — using raw")
            return nil
        }
        DebugLog.log("polish: ok in \(Int(-started.timeIntervalSinceNow * 1000))ms · '\(String(text.prefix(60)))' → '\(String(cleaned.prefix(60)))'")
        return cleaned
        #else
        return nil
        #endif
    }

    /// User-invoked rewrite for TransformService. Unlike inline polish this is
    /// ALLOWED to rewrite — the user asked for it, sees the result, can ⌘Z.
    /// Basic sanity only: non-empty, not absurdly long.
    static func transform(_ text: String, instructions: String, timeout: TimeInterval = 8) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        guard text.count < 8000 else { return nil }

        let session = LanguageModelSession(instructions: instructions)
        let result: String? = await withTimeout(seconds: timeout) { () -> String? in
            do {
                return try await session.respond(to: "<text>\n\(text)\n</text>",
                                                 options: GenerationOptions(sampling: .greedy)).content
            } catch {
                DebugLog.log("transform: model failed (\(error))")
                return nil
            }
        } ?? nil

        guard var cleaned = result?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        cleaned = cleaned
            .replacingOccurrences(of: "<text>", with: "")
            .replacingOccurrences(of: "</text>", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“” \n"))
        guard !cleaned.isEmpty, cleaned.count < text.count * 4 + 200 else { return nil }
        return cleaned
        #else
        return nil
        #endif
    }

    /// Title + topic tags for the history, in one schema-constrained call.
    /// Runs in the background after insertion — can never affect pasted text.
    /// Returns nil when unavailable, unsupported language, timeout, or failure.
    static func label(_ text: String, timeout: TimeInterval = 5) async -> (title: String, tags: [String])? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        guard text.count > 40, text.count < 6000 else { return nil }

        guard let schema = try? GenerationSchema(
            root: DynamicGenerationSchema(
                name: "EntryMeta",
                description: "Metadata labeling a dictation transcript",
                properties: [
                    .init(name: "title",
                          description: "3-6 word title describing the dictation",
                          schema: DynamicGenerationSchema(type: String.self)),
                    .init(name: "tags",
                          description: "1-3 short lowercase topic tags",
                          schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self),
                                                          maximumElements: 3)),
                ]),
            dependencies: []) else { return nil }

        let session = LanguageModelSession(instructions: "You label dictation transcripts for a searchable history.")
        let result: (String, [String])? = await withTimeout(seconds: timeout) { () -> (String, [String])? in
            do {
                let content = try await session.respond(to: "Label this dictation:\n\(text)",
                                                        schema: schema,
                                                        options: GenerationOptions(sampling: .greedy)).content
                let title: String = try content.value(String.self, forProperty: "title")
                let tags: [String] = try content.value([String].self, forProperty: "tags")
                return (title, tags)
            } catch {
                DebugLog.log("label: failed (\(error))")
                return nil
            }
        } ?? nil

        guard let (title, tags) = result,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (title.trimmingCharacters(in: .whitespaces),
                tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        #else
        return nil
        #endif
    }

    /// Deletion-only cleanup: the output must be the speaker's words, in the
    /// speaker's order, with only removals (fillers, false starts, corrected-
    /// away segments) and punctuation changes. Anything that adds, replaces,
    /// or reorders words — a paraphrase, a summary, a chatbot reply — fails.
    private static func looksLikeCleanup(of raw: String, candidate: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let rawWords = words(raw)
        let candWords = words(candidate)
        guard !candWords.isEmpty, !rawWords.isEmpty else { return false }

        // A cleanup only deletes: it can't grow, and it shouldn't compress away
        // meaning either.
        let lengthRatio = Double(candWords.count) / Double(rawWords.count)
        guard lengthRatio > 0.55, lengthRatio < 1.15 else { return false }

        // ≥90% of the output must be an ordered subsequence of the input.
        var searchFrom = 0
        var matched = 0
        for word in candWords {
            var j = searchFrom
            while j < rawWords.count && rawWords[j] != word { j += 1 }
            if j < rawWords.count {
                matched += 1
                searchFrom = j + 1
            }
        }
        return Double(matched) / Double(candWords.count) >= 0.9
    }
}
