import AVFoundation

/// Captures the default microphone into memory as 16 kHz mono floats (what Parakeet expects).
/// Audio is never written to disk.
final class AudioRecorder {
    static let sampleRate = 16_000.0

    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var latestLevel: Float = 0

    var isRecording: Bool { engine?.isRunning ?? false }

    /// RMS loudness of the most recent audio chunk (0...1 linear), for the on-screen meter.
    var level: Float { lock.withLock { latestLevel } }

    func start() throws {
        let engine = preparedEngine()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            latestLevel = 0
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw RecorderError.noMicrophone }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inputFormat.sampleRate) + 64
            guard let self, let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            else { return }
            var consumed = false
            let status = converter.convert(to: converted, error: nil) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = converted.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
            let rms = chunk.isEmpty ? 0 : (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            self.lock.withLock {
                self.samples.append(contentsOf: chunk)
                self.latestLevel = rms
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return lock.withLock { samples }
    }

    /// Reuses one engine between recordings so the mic starts quickly, and rebuilds it when
    /// the input device changes (e.g. AirPods connecting).
    private func preparedEngine() -> AVAudioEngine {
        if let engine { return engine }

        let engine = AVAudioEngine()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isRecording else { return }
            self.discardEngine()
        }
        self.engine = engine
        return engine
    }

    private func discardEngine() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        engine = nil
    }
}

enum RecorderError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "No microphone input is available." }
}
