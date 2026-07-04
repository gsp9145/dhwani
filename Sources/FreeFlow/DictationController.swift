import AppKit
import AVFoundation
import Speech

/// Orchestrates one dictation: key down → capture + stream-transcribe →
/// key up → finalize → (optional AI polish) → insert → save history.
@available(macOS 26.0, *)
final class DictationController {
    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    private var locale = Locale(identifier: "en_US")
    private var cachedAudioFormat: AVAudioFormat?
    private(set) var assetsReady = false

    private var recorder: AudioRecorder?
    private var session: TranscriptionSession?
    private var startedAt = Date()
    private var targetAppName: String?
    private var targetBundleID: String?
    private var maxDurationTimer: Timer?

    private static let maxDuration: TimeInterval = 300

    /// Resolve locale, download the on-device model if needed, cache the audio format.
    func prepare() {
        Task { @MainActor in
            self.locale = await SpeechAssets.resolveLocale()
            let status = await SpeechAssets.status(locale: self.locale)
            if status != .installed {
                HUD.shared.show(.info("Downloading Apple speech model…"))
            }
            do {
                try await SpeechAssets.ensureInstalled(locale: self.locale)
                self.cachedAudioFormat = await SpeechAssets.bestAudioFormat(locale: self.locale)
                self.assetsReady = true
                if status != .installed {
                    HUD.shared.show(.info("Ready — hold \(Settings.shared.holdKey.shortName) to dictate"))
                    HUD.shared.hide(after: 2.5)
                }
            } catch {
                HUD.shared.show(.error("Speech model download failed — check your connection"))
                HUD.shared.hide(after: 4)
                NSLog("FreeFlow: asset install failed: \(error)")
            }
        }
    }

    // MARK: - Session lifecycle (all on main thread)

    func startDictation() {
        guard state == .idle else { return }

        guard Permissions.micStatus == .authorized else {
            Permissions.requestMic { granted in
                if !granted {
                    HUD.shared.show(.error("Microphone access is required — enable it in System Settings"))
                    HUD.shared.hide(after: 3)
                }
            }
            return
        }
        guard assetsReady else {
            HUD.shared.show(.error("Speech model still downloading — try again in a moment"))
            HUD.shared.hide(after: 2.5)
            return
        }

        startedAt = Date()
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetAppName = frontmost?.localizedName
        targetBundleID = frontmost?.bundleIdentifier

        let session = TranscriptionSession(locale: locale)
        session.onPartial = { [weak self] text in
            guard self?.state == .recording else { return }
            HUD.shared.update(text: text)
        }
        self.session = session
        session.begin()

        let recorder = AudioRecorder()
        self.recorder = recorder
        do {
            try recorder.start(targetFormat: cachedAudioFormat) { buffer in
                session.feed(buffer)
            }
        } catch {
            session.cancel()
            self.session = nil
            self.recorder = nil
            HUD.shared.show(.error("Couldn't start the microphone"))
            HUD.shared.hide(after: 2.5)
            Sounds.error()
            return
        }

        state = .recording
        Sounds.start()
        HUD.shared.show(.listening(""))

        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
            self?.stopDictation()
        }
    }

    func stopDictation() {
        guard state == .recording, let session, let recorder else { return }
        state = .processing
        maxDurationTimer?.invalidate()
        HUD.shared.show(.processing)

        Task { @MainActor in
            // Capture a short audio tail so the last word isn't clipped.
            try? await Task.sleep(nanoseconds: 120_000_000)
            recorder.stop()

            var text = ""
            do {
                text = try await session.finishAndCollect()
            } catch {
                NSLog("FreeFlow: transcription failed: \(error)")
            }

            guard !text.isEmpty else {
                HUD.shared.show(.error("No speech detected"))
                HUD.shared.hide(after: 1.6)
                Sounds.error()
                self.reset()
                return
            }

            if Settings.shared.aiPolish, let polished = await AIFormatter.polish(text) {
                text = polished
            }

            let durationMs = Int(Date().timeIntervalSince(self.startedAt) * 1000)
            let inserted = TextInserter.insert(text)
            HistoryStore.shared.save(text: text,
                                     appName: self.targetAppName,
                                     bundleID: self.targetBundleID,
                                     durationMs: durationMs)

            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            if inserted {
                HUD.shared.show(.done(words: words))
                HUD.shared.hide(after: 1.2)
                Sounds.done()
            } else {
                HUD.shared.show(.error("Secure field — text copied to clipboard instead"))
                HUD.shared.hide(after: 3)
            }
            self.reset()
        }
    }

    func cancelDictation() {
        guard state == .recording else { return }
        maxDurationTimer?.invalidate()
        recorder?.stop()
        session?.cancel()
        HUD.shared.hide()
        reset()
    }

    private func reset() {
        session = nil
        recorder = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        state = .idle
    }
}
