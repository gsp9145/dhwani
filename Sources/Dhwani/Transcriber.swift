import AVFoundation
import Foundation
import Speech

/// Which on-device speech engine serves a locale.
/// - flagship: SpeechTranscriber — Apple's best models, ~30 locales
/// - dictation: DictationTranscriber — older engine, 54 locales incl. Hindi,
///   Arabic, Russian, Thai… the long-tail fallback
enum EngineKind: String {
    case flagship
    case dictation
}

/// A language the user can pick, resolved against both engines.
struct LanguageChoice: Identifiable, Hashable {
    let id: String // bcp47
    let flagship: Bool

    var displayName: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

/// Locale + model-asset management for Apple's on-device speech engines.
@available(macOS 26.0, *)
enum SpeechAssets {
    /// Honor the user's language pick; fall back to the system locale.
    /// Flagship engine wins whenever it supports the locale.
    static func resolveLocaleAndEngine() async -> (Locale, EngineKind) {
        let preference = Settings.shared.dictationLocale
        if preference != "auto" {
            let wanted = Locale(identifier: preference)
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
                return (match, .flagship)
            }
            if let match = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
                return (match, .dictation)
            }
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return (match, .flagship)
        }
        if let match = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return (match, .dictation)
        }
        return (Locale(identifier: "en_US"), .flagship)
    }

    /// Everything dictatable on this machine, across both engines.
    static func availableChoices() async -> [LanguageChoice] {
        var byID: [String: LanguageChoice] = [:]
        for locale in await DictationTranscriber.supportedLocales {
            let id = locale.identifier(.bcp47)
            byID[id] = LanguageChoice(id: id, flagship: false)
        }
        for locale in await SpeechTranscriber.supportedLocales {
            let id = locale.identifier(.bcp47)
            byID[id] = LanguageChoice(id: id, flagship: true)
        }
        return byID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func probe(locale: Locale, engine: EngineKind) -> any SpeechModule {
        switch engine {
        case .flagship:
            return SpeechTranscriber(locale: locale, preset: .transcription)
        case .dictation:
            return DictationTranscriber(locale: locale, preset: .shortDictation)
        }
    }

    static func status(locale: Locale, engine: EngineKind) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [probe(locale: locale, engine: engine)])
    }

    /// Downloads and installs the on-device model for the locale if needed.
    static func ensureInstalled(locale: Locale, engine: EngineKind,
                                onProgress: ((Progress) -> Void)? = nil) async throws {
        let module = probe(locale: locale, engine: engine)
        let status = await AssetInventory.status(forModules: [module])
        if status == .installed { return }

        // Reserve the locale so the system doesn't evict its assets later.
        if await AssetInventory.reservedLocales.count >= AssetInventory.maximumReservedLocales,
           let oldest = await AssetInventory.reservedLocales.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onProgress?(request.progress)
            try await request.downloadAndInstall()
        }
    }

    static func bestAudioFormat(locale: Locale, engine: EngineKind) async -> AVAudioFormat? {
        await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe(locale: locale, engine: engine)])
    }
}

/// One dictation's worth of streaming transcription. Create it synchronously on
/// key-down (so the audio stream can start buffering immediately), then `begin()`
/// starts the analyzer; buffers queued in the AsyncStream are never lost.
@available(macOS 26.0, *)
final class TranscriptionSession {
    private enum Engine {
        case flagship(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .flagship(let t): return t
            case .dictation(let t): return t
            }
        }
    }

    private let engine: Engine
    private let analyzer: SpeechAnalyzer
    private let stream: AsyncStream<AnalyzerInput>
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation

    private var startTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?

    private let stateLock = NSLock()
    private var finalized = ""
    private var volatile = ""

    /// Called on the main thread with the live (partial) transcript.
    var onPartial: ((String) -> Void)?

    init(locale: Locale, engineKind: EngineKind) {
        switch engineKind {
        case .flagship:
            engine = .flagship(SpeechTranscriber(locale: locale,
                                                 transcriptionOptions: [],
                                                 reportingOptions: [.volatileResults, .fastResults],
                                                 attributeOptions: []))
        case .dictation:
            engine = .dictation(DictationTranscriber(locale: locale,
                                                     contentHints: [],
                                                     transcriptionOptions: [.punctuation],
                                                     reportingOptions: [.volatileResults],
                                                     attributeOptions: []))
        }
        // .processLifetime keeps the speech model hot between dictations, so the
        // second and later sessions start with near-zero model-load latency.
        self.analyzer = SpeechAnalyzer(modules: [engine.module],
                                       options: SpeechAnalyzer.Options(priority: .userInitiated,
                                                                       modelRetention: .processLifetime))
        (self.stream, self.inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
    }

    func begin() {
        resultsTask = Task { [weak self] in
            await self?.consumeResults()
        }
        // Bias recognition toward the user's vocabulary (names, jargon).
        let vocabulary = PersonalDictionary.shared.vocabulary
        startTask = Task { [analyzer, stream] in
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: vocabulary]
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: stream)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        inputBuilder.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends input, waits for the engine to finalize everything, and returns the transcript.
    func finishAndCollect() async throws -> String {
        inputBuilder.finish()
        try await startTask?.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Volatile text should have been superseded by final results; keep it only
    /// if the engine never finalized its range.
    private func snapshot() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return finalized + volatile
    }

    private func record(_ text: String, isFinal: Bool) -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        return finalized + volatile
    }

    func cancel() {
        onPartial = nil
        inputBuilder.finish()
        resultsTask?.cancel()
        Task { [analyzer] in
            await analyzer.cancelAndFinishNow()
        }
    }

    private func consumeResults() async {
        do {
            switch engine {
            case .flagship(let transcriber):
                for try await result in transcriber.results {
                    publish(String(result.text.characters), isFinal: result.isFinal)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    publish(String(result.text.characters), isFinal: result.isFinal)
                }
            }
        } catch {
            NSLog("Dhwani: transcriber results ended with error: \(error)")
        }
    }

    private func publish(_ text: String, isFinal: Bool) {
        let snapshot = record(text, isFinal: isFinal)
        DispatchQueue.main.async { [weak self] in
            self?.onPartial?(snapshot)
        }
    }
}
