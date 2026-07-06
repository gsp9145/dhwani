import AppKit
import AVFoundation
import Speech

/// Orchestrates one dictation: key down → capture + stream-transcribe →
/// key up → finalize → (optional AI polish) → insert → save history.
/// All state transitions happen on the main thread.
@available(macOS 26.0, *)
final class DictationController {
    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle {
        didSet {
            DebugLog.log("state: \(oldValue) → \(state)")
            onStateChange?(state)
        }
    }
    var onStateChange: ((State) -> Void)?
    /// Wired to HotkeyManager: is the push-to-talk key physically held right now?
    var hotkeyStillHeld: (() -> Bool)?

    private var locale = Locale(identifier: "en_US")
    private var cachedAudioFormat: AVAudioFormat?
    private(set) var assetsReady = false
    private var preparing = false

    /// One persistent recorder: the audio engine stays warm across dictations
    /// so key-down → first captured buffer is fast (a cold engine clipped
    /// first words). The mic is only live while a dictation is in flight.
    private let recorder = AudioRecorder()
    private var session: TranscriptionSession?
    private var startedAt = Date()
    private var targetAppName: String?
    private var targetBundleID: String?
    private var maxDurationTimer: Timer?

    /// Bumped on every start and cancel; in-flight pipelines compare against it
    /// and abandon their work when it no longer matches.
    private var generation = 0
    /// Set when the hotkey was pressed while a previous dictation was still
    /// finalizing; consumed in reset().
    private var pendingStart = false

    private static let maxDuration: TimeInterval = 300
    private static let handsFreeMaxDuration: TimeInterval = 1200 // 20 min, like Wispr
    private static let finalizeTimeout: TimeInterval = 20

    /// Resolve locale, download the on-device model if needed, cache the audio
    /// format, and warm the audio engine.
    func prepare() {
        recorder.onLevel = { level in
            HUD.shared.updateLevel(level)
        }
        recorder.onConfigurationChange = { [weak self] in
            // Input device changed (AirPods connected, mic unplugged): the
            // engine stops delivering buffers. Salvage what we have.
            guard let self, self.state == .recording else { return }
            HUD.shared.show(.error("Microphone changed — finishing dictation"))
            self.stopDictation()
        }
        recorder.warmUp()

        guard !preparing, !assetsReady else { return }
        preparing = true
        Task { @MainActor in
            defer { self.preparing = false }
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
                HUD.shared.show(.error("Speech model download failed — will retry next time you dictate"))
                HUD.shared.hide(after: 4)
                NSLog("Dhwani: asset install failed: \(error)")
            }
        }
    }

    // MARK: - Session lifecycle (all on main thread)

    func startDictation() {
        guard state == .idle else {
            // Still finalizing the previous dictation: queue this press instead
            // of silently swallowing the user's speech.
            if state == .processing { pendingStart = true }
            return
        }

        guard Permissions.micStatus == .authorized else {
            Permissions.requestMic { granted in
                if granted {
                    HUD.shared.show(.info("Microphone ready — hold \(Settings.shared.holdKey.shortName) and speak"))
                    HUD.shared.hide(after: 2.5)
                } else {
                    HUD.shared.show(.error("Microphone access is required — enable it in System Settings"))
                    HUD.shared.hide(after: 3)
                }
            }
            return
        }
        guard assetsReady else {
            prepare() // retry a failed or still-running model download
            HUD.shared.show(.error("Speech model not ready yet — try again in a moment"))
            HUD.shared.hide(after: 2.5)
            return
        }

        generation += 1
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

        do {
            let audioStart = Date()
            try recorder.start(targetFormat: cachedAudioFormat) { buffer in
                session.feed(buffer)
            }
            DebugLog.log("audio: engine live in \(Int(-audioStart.timeIntervalSinceNow * 1000))ms")
        } catch {
            session.cancel()
            self.session = nil
            HUD.shared.show(.error("Couldn't start the microphone"))
            HUD.shared.hide(after: 2.5)
            Sounds.error()
            return
        }

        state = .recording
        Sounds.start()
        HUD.shared.setHandsFree(false)
        HUD.shared.show(.listening)

        maxDurationTimer?.invalidate()
        let timer = Timer(timeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
            self?.stopDictation()
        }
        RunLoop.main.add(timer, forMode: .common)
        maxDurationTimer = timer
    }

    /// Double-tap locked recording on: extend the cap and mark the HUD.
    func lockHandsFree() {
        guard state == .recording else { return }
        maxDurationTimer?.invalidate()
        let timer = Timer(timeInterval: Self.handsFreeMaxDuration, repeats: false) { [weak self] _ in
            self?.stopDictation()
        }
        RunLoop.main.add(timer, forMode: .common)
        maxDurationTimer = timer
        HUD.shared.setHandsFree(true)
        Sounds.start()
        // Announce the lock briefly, then return to the (red) waveform.
        HUD.shared.show(.info("Locked on — tap \(Settings.shared.holdKey.shortName) to finish · Esc cancels"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.state == .recording else { return }
            HUD.shared.show(.listening)
        }
    }

    func stopDictation() {
        guard state == .recording, let session else { return }
        state = .processing
        maxDurationTimer?.invalidate()
        HUD.shared.show(.processing)
        let gen = generation

        Task { @MainActor in
            // Capture a short audio tail so the last word isn't clipped.
            try? await Task.sleep(nanoseconds: 120_000_000)
            recorder.stop()

            // Watchdog: a stalled analyzer must never brick the app in .processing.
            let collected = await withTimeout(seconds: Self.finalizeTimeout) {
                (try? await session.finishAndCollect()) ?? ""
            }
            if collected == nil {
                NSLog("Dhwani: transcription stalled; abandoning session")
                session.cancel()
            }
            guard gen == self.generation else { return } // cancelled meanwhile

            var text = (collected ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            DebugLog.log("stop: collected \(text.count) chars (timedOut=\(collected == nil))")
            guard !text.isEmpty else {
                HUD.shared.show(.error(collected == nil ? "Transcription stalled — try again" : "No speech detected"))
                HUD.shared.hide(after: 1.6)
                Sounds.error()
                self.reset()
                return
            }

            if Settings.shared.aiPolish, let polished = await AIFormatter.polish(text) {
                text = polished
            }
            guard gen == self.generation else { return } // cancelled during polish
            text = PersonalDictionary.shared.applyReplacements(to: text)

            let durationMs = Int(Date().timeIntervalSince(self.startedAt) * 1000)
            switch TextInserter.insert(text) {
            case .inserted:
                HistoryStore.shared.save(text: text,
                                         appName: self.targetAppName,
                                         bundleID: self.targetBundleID,
                                         durationMs: durationMs)
                let words = text.split(whereSeparator: { $0.isWhitespace }).count
                HUD.shared.show(.done(words: words))
                HUD.shared.hide(after: 1.2)
                Sounds.done()
            case .secureInputBlocked(let culprit):
                // History deliberately skipped: secure input usually means a
                // password was dictated; never persist that to plaintext.
                DebugLog.log("insert: blocked by secure input (culprit: \(culprit ?? "unknown"))")
                let message: String
                if let culprit,
                   culprit.localizedCaseInsensitiveContains("terminal") ||
                   culprit.localizedCaseInsensitiveContains("iterm") {
                    message = "\(culprit) has Secure Keyboard Entry on — copied instead (⌘V). Turn it off in \(culprit)'s menu."
                } else if let culprit {
                    message = "\(culprit) is blocking paste (secure input) — copied instead, press ⌘V"
                } else {
                    message = "Secure input is on — copied instead, press ⌘V"
                }
                HUD.shared.show(.error(message))
                HUD.shared.hide(after: 5)
            }
            self.reset()
        }
    }

    func cancelDictation() {
        guard state != .idle else { return }
        teardownSession()
        HUD.shared.show(.info("Canceled"))
        HUD.shared.hide(after: 0.7)
    }

    /// A lone quick tap of the hotkey: not a gesture, so teach instead of alarm.
    func dismissAccidentalTap() {
        guard state != .idle else { return }
        teardownSession()
        HUD.shared.show(.info("Hold \(Settings.shared.holdKey.shortName) to dictate · double-tap to lock hands-free"))
        HUD.shared.hide(after: 1.8)
    }

    private func teardownSession() {
        generation += 1 // any in-flight pipeline abandons at its next check
        pendingStart = false
        maxDurationTimer?.invalidate()
        recorder.stop()
        session?.cancel()
        HUD.shared.setHandsFree(false)
        reset()
    }

    private func reset() {
        session = nil
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        state = .idle

        if pendingStart {
            pendingStart = false
            if hotkeyStillHeld?() == true {
                startDictation()
            } else {
                HUD.shared.show(.error("Too fast — the previous dictation was still finishing"))
                HUD.shared.hide(after: 2)
                Sounds.error()
            }
        }
    }
}
