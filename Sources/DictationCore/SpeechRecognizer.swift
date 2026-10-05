import FluidAudio
import Foundation

public struct Recognition: Sendable {
    public let text: String
    public let tokenTimings: [TokenTiming]
    /// The exact audio that was recognized (after padding), needed by the vocabulary pass.
    public let audio: [Float]
}

/// Parakeet TDT 0.6B v2 (English) on the Neural Engine. Chosen in Phase 1: 7.6% WER on
/// the user's quiet voice vs 20.9% for Apple's SpeechTranscriber.
public final class SpeechRecognizer {
    public static let sampleRate = 16_000.0
    /// Parakeet needs at least 0.3 s; very short words decode more reliably with a little padding.
    private static let minimumSamples = Int(sampleRate)

    private var manager: AsrManager?

    public init() {}

    /// Loads from the local model cache (downloads once on the very first run), then warms up
    /// so the first real dictation is as fast as the rest.
    public func load() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        _ = try? await recognize([Float](repeating: 0, count: Self.minimumSamples))
    }

    public func recognize(_ samples: [Float]) async throws -> Recognition {
        guard let manager else { throw RecognizerError.notLoaded }
        var audio = samples
        if audio.count < Self.minimumSamples {
            audio.append(contentsOf: [Float](repeating: 0, count: Self.minimumSamples - audio.count))
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return Recognition(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenTimings: result.tokenTimings ?? [],
            audio: audio
        )
    }
}

public enum RecognizerError: LocalizedError {
    case notLoaded

    public var errorDescription: String? { "The speech model isn't loaded yet." }
}
