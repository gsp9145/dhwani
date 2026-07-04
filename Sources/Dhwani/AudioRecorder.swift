import AVFoundation

/// Captures microphone audio with AVAudioEngine and delivers buffers converted
/// to the transcriber's preferred format.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?

    /// Fired on the main queue when the input hardware changes mid-capture
    /// (device switch, AirPods connect) — the engine stops delivering buffers.
    var onConfigurationChange: (() -> Void)?

    /// Microphone level 0…1 per buffer, delivered on the main queue (drives the HUD waveform).
    var onLevel: ((Float) -> Void)?

    // Read on the audio render thread, written on the main thread.
    private let runningLock = NSLock()
    private var _running = false
    var isRunning: Bool {
        get { runningLock.lock(); defer { runningLock.unlock() }; return _running }
        set { runningLock.lock(); defer { runningLock.unlock() }; _running = newValue }
    }

    func start(targetFormat: AVAudioFormat?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw NSError(domain: "Dhwani", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device is available."])
        }

        var converter: AVAudioConverter?
        var target: AVAudioFormat?
        if let requested = targetFormat, requested != native {
            converter = AVAudioConverter(from: native, to: requested)
            // No priming: we convert independent small buffers; priming would
            // swallow leading samples from every one of them.
            converter?.primeMethod = .none
            target = requested
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onConfigurationChange?()
        }

        isRunning = true
        let levelHandler = onLevel
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self, self.isRunning else { return }
            if let levelHandler {
                let level = Self.rmsLevel(buffer)
                DispatchQueue.main.async { levelHandler(level) }
            }
            if let converter, let target {
                if let converted = Self.convert(buffer, with: converter, to: target) {
                    onBuffer(converted)
                }
            } else {
                onBuffer(buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            isRunning = false
            input.removeTap(onBus: 0)
            removeObserver()
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func removeObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    /// RMS of the buffer mapped from dB into 0…1 for waveform display.
    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < n {
            let v = data[i]
            sum += v * v
            count += 1
            i += 4 // every 4th sample is plenty for a VU meter
        }
        guard count > 0 else { return 0 }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 50) / 42)) // −50 dB…−8 dB → 0…1
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
