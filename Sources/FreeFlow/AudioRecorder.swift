import AVFoundation

/// Captures microphone audio with AVAudioEngine and delivers buffers converted
/// to the transcriber's preferred format.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false

    func start(targetFormat: AVAudioFormat?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, native.channelCount > 0 else {
            throw NSError(domain: "FreeFlow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device is available."])
        }

        var converter: AVAudioConverter?
        var target: AVAudioFormat?
        if let requested = targetFormat, requested != native {
            converter = AVAudioConverter(from: native, to: requested)
            target = requested
        }

        isRunning = true
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self, self.isRunning else { return }
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
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
