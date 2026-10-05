import AVFoundation
import Foundation

/// Walks through prompts.txt: shows a sentence, records you reading it, and saves
/// TestClips/mine/clip_NNN.wav (16 kHz mono) next to clip_NNN.txt (what you were asked to say).
/// Already-recorded clips are skipped, so you can quit and resume any time.
@main
struct RecordClips {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let promptsPath = value(of: "--prompts", in: arguments) ?? "prompts.txt"
        // Apple's voice processing = noise suppression + automatic gain, the same path FaceTime uses.
        let voiceProcessing = arguments.contains("--voice-processing")
        let defaultOutput = voiceProcessing ? "TestClips/mine-vp" : "TestClips/mine"
        let outputDirectory = URL(fileURLWithPath: value(of: "--out", in: arguments) ?? defaultOutput)

        guard let promptText = try? String(contentsOfFile: promptsPath, encoding: .utf8) else {
            fail("can't read \(promptsPath)")
        }
        let prompts = promptText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard requestMicrophoneAccess() else {
            fail("""
                microphone access denied. Allow your terminal app in
                System Settings → Privacy & Security → Microphone, then run again.
                """)
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "default input"
        print("""
            Microphone: \(deviceName)\(voiceProcessing ? " (voice processing on: noise suppression + auto gain)" : "")
            Saving to: \(outputDirectory.path)
            \(prompts.count) prompts. For each one: press Enter, read the sentence naturally, press Enter again.
            Tip: speak the way you'd dictate a real message. Type q + Enter at any prompt to stop.

            """)

        let recorder: Recorder
        do {
            recorder = try Recorder(voiceProcessing: voiceProcessing)
        } catch {
            fail("couldn't turn on voice processing (\(error)). Try again without --voice-processing.")
        }
        for (index, prompt) in prompts.enumerated() {
            let name = String(format: "clip_%03d", index + 1)
            let audioURL = outputDirectory.appendingPathComponent("\(name).wav")
            if FileManager.default.fileExists(atPath: audioURL.path) { continue }

            while true {
                print("[\(index + 1)/\(prompts.count)] \(prompt)")
                print("  Enter = start recording, s = skip, q = quit › ", terminator: "")
                switch readLine()?.lowercased() {
                case "q", nil: print("Stopped. Run again to continue where you left off."); return
                case "s": print(""); break
                default:
                    do {
                        try recorder.start()
                    } catch {
                        fail("couldn't start the microphone: \(error)")
                    }
                    print("  ● recording… Enter to stop › ", terminator: "")
                    _ = readLine()
                    let samples = recorder.stop()
                    let seconds = Double(samples.count) / Recorder.sampleRate
                    if seconds < 0.5 {
                        print("  too short (\(String(format: "%.1f", seconds)) s), let's try again.\n")
                        continue
                    }
                    do {
                        try Recorder.writeWAV(samples, to: audioURL)
                        try prompt.write(
                            to: outputDirectory.appendingPathComponent("\(name).txt"),
                            atomically: true, encoding: .utf8)
                    } catch {
                        fail("couldn't save \(name): \(error)")
                    }
                    print(String(format: "  saved %@ (%.1f s)\n", name, seconds))
                }
                break
            }
        }
        print("All prompts recorded in \(outputDirectory.path). Next: swift run -c release Bench")
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func requestMicrophoneAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; done.signal() }
            done.wait()
            return granted
        default: return false
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

/// Captures the default microphone and converts it to 16 kHz mono float samples in memory.
final class Recorder {
    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []

    init(voiceProcessing: Bool = false) throws {
        guard voiceProcessing else { return }
        try engine.inputNode.setVoiceProcessingEnabled(true)
        // Voice processing runs the input and output sides together, so the output side must exist.
        _ = engine.mainMixerNode
    }

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw CocoaError(.featureUnsupported) }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
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
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
