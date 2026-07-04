import AVFoundation
import Foundation
import Speech

/// Locale + model-asset management for Apple's on-device SpeechAnalyzer engine.
@available(macOS 26.0, *)
enum SpeechAssets {
    static func resolveLocale() async -> Locale {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        return Locale(identifier: "en_US")
    }

    static func status(locale: Locale) async -> AssetInventory.Status {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        return await AssetInventory.status(forModules: [probe])
    }

    /// Downloads and installs the on-device model for the locale if needed.
    static func ensureInstalled(locale: Locale, onProgress: ((Progress) -> Void)? = nil) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [probe])
        if status == .installed { return }

        // Reserve the locale so the system doesn't evict its assets later.
        if await AssetInventory.reservedLocales.count >= AssetInventory.maximumReservedLocales,
           let oldest = await AssetInventory.reservedLocales.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            onProgress?(request.progress)
            try await request.downloadAndInstall()
        }
    }

    static func bestAudioFormat(locale: Locale) async -> AVAudioFormat? {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
    }
}

/// One dictation's worth of streaming transcription. Create it synchronously on
/// key-down (so the audio stream can start buffering immediately), then `begin()`
/// starts the analyzer; buffers queued in the AsyncStream are never lost.
@available(macOS 26.0, *)
final class TranscriptionSession {
    private let transcriber: SpeechTranscriber
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

    init(locale: Locale) {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        self.transcriber = transcriber
        // .processLifetime keeps the speech model hot between dictations, so the
        // second and later sessions start with near-zero model-load latency.
        self.analyzer = SpeechAnalyzer(modules: [transcriber],
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
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                let snapshot = record(text, isFinal: result.isFinal)
                DispatchQueue.main.async { [weak self] in
                    self?.onPartial?(snapshot)
                }
            }
        } catch {
            NSLog("Dhwani: transcriber results ended with error: \(error)")
        }
    }
}
