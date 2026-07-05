import AVFoundation

/// Persistent microphone capture. One engine lives for the app's lifetime and
/// is prepared ahead of time — creating a cold AVAudioEngine on every key-down
/// cost ~100ms of hardware spin-up, which clipped the first words of short
/// dictations. The mic is only live between start() and stop().
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?

    /// Fired on the main queue when the input hardware changes mid-capture
    /// (device switch, AirPods connect) — the engine stops delivering buffers.
    var onConfigurationChange: (() -> Void)?

    /// Microphone level 0…1 per buffer, delivered on the main queue (drives the HUD waveform).
    var onLevel: ((Float) -> Void)?

    // Written on the main thread, read on the audio render thread.
    private let stateLock = NSLock()
    private var _running = false
    private var _bufferHandler: ((AVAudioPCMBuffer) -> Void)?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _running
    }

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.onConfigurationChange?()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// Touch the input hardware and pre-allocate render resources so the first
    /// real start() is fast. Does not turn the microphone on.
    func warmUp() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
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

        stateLock.lock()
        _bufferHandler = onBuffer
        _running = true
        stateLock.unlock()

        let levelHandler = onLevel
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self else { return }
            self.stateLock.lock()
            let handler = self._running ? self._bufferHandler : nil
            self.stateLock.unlock()
            guard let handler else { return }
            if let levelHandler {
                let level = Self.rmsLevel(buffer)
                DispatchQueue.main.async { levelHandler(level) }
            }
            if let converter, let target {
                if let converted = Self.convert(buffer, with: converter, to: target) {
                    handler(converted)
                }
            } else {
                handler(buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stateLock.lock()
            _running = false
            _bufferHandler = nil
            stateLock.unlock()
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        stateLock.lock()
        _running = false
        _bufferHandler = nil
        stateLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        return max(0, min(1, (db + 52) / 30)) // −52 dB…−22 dB → 0…1: normal speech fills the range
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
