import FluidAudio
import Foundation

public struct Recognition: Sendable {
    public let text: String
    public let tokenTimings: [TokenTiming]
    /// The exact audio that was recognized (after padding), needed by the vocabulary pass.
    public let audio: [Float]

    public var words: [RecognizedWord] {
        RecognizedWord.group(tokenTimings.map { (token: $0.token, confidence: $0.confidence) })
    }
}

/// One transcript word and how sure Parakeet was of it.
public struct RecognizedWord: Sendable, Equatable {
    public let text: String
    /// The lowest token probability inside the word (0...1): a word is only as certain as its weakest piece.
    public let confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }

    /// SentencePiece pieces → words: a piece starting with a space begins a new word. Punctuation
    /// pieces stay attached to their word but don't lower its confidence; the review fixes those anyway.
    public static func group(_ pieces: [(token: String, confidence: Float)]) -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        var text = ""
        var confidence: Float = 1
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { words.append(RecognizedWord(text: trimmed, confidence: confidence)) }
            text = ""
            confidence = 1
        }
        for piece in pieces {
            if piece.token.hasPrefix(" ") { flush() }
            text += piece.token
            if piece.token.contains(where: { $0.isLetter || $0.isNumber }) {
                confidence = min(confidence, piece.confidence)
            }
        }
        flush()
        return words
    }
}

/// Parakeet TDT 0.6B v2 (English) on the Neural Engine. Chosen in Phase 1: 7.6% WER on
/// the user's quiet voice vs 20.9% for Apple's SpeechTranscriber.
public final class SpeechRecognizer {
    public static let sampleRate = 16_000.0
    /// Parakeet needs at least 0.3 s; very short words decode more reliably with a little padding.
    private static let minimumSamples = Int(sampleRate)

    /// The copy of the model shipped inside the app (Contents/Resources/Models/…), added by
    /// `Scripts/build_app.sh --bundle-model` so a shared app works offline from the first launch.
    /// The folder name is what FluidAudio expects for v2.
    public static let bundledModelPath = "Models/parakeet-tdt-0.6b-v2"

    private var manager: AsrManager?
    /// "app bundle" or "shared cache", for the log and the packaging check.
    public private(set) var modelSource = ""

    public init() {}

    /// Loads the model, then warms up so the first real dictation is as fast as the rest.
    public func load() async throws {
        let models = try await loadModels()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        _ = try? await recognize([Float](repeating: 0, count: Self.minimumSamples))
    }

    /// The copy inside the app if there is one; otherwise the shared cache in Application Support,
    /// downloading it once from Hugging Face if needed.
    private func loadModels() async throws -> AsrModels {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(Self.bundledModelPath),
           AsrModels.modelsExist(at: bundled, version: .v2) {
            // Offline mode, so a failed load can't make FluidAudio "repair" the folder by deleting it
            // and downloading into the signed app. On failure, fall through to the shared cache.
            ModelHub.offlineMode = true
            defer { ModelHub.offlineMode = false }
            if let models = try? await AsrModels.load(from: bundled, version: .v2) {
                modelSource = "app bundle"
                return models
            }
        }
        modelSource = "shared cache"
        return try await AsrModels.downloadAndLoad(version: .v2)
    }

    /// For checks and tools: transcribe an audio file in any common format.
    public func recognize(fileAt url: URL) async throws -> Recognition {
        try await recognize(try AudioConverter().resampleAudioFile(url))
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
