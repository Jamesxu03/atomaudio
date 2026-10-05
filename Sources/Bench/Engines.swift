import AVFoundation
import DictationCore
import FluidAudio
import Foundation
import Speech

enum EngineID: String, CaseIterable {
    case parakeetV2 = "parakeet-v2"
    case parakeetV3 = "parakeet-v3"
    case phonon2 = "parakeet-phonon2"
    case ultra = "parakeet-ultra"
    case appleSpeech = "apple-speech"
    case appleDictation = "apple-dictation"
    /// The app's pipeline: Parakeet v2 + word-list boosting + cleanup rules (+ on-device AI review).
    case pipelineNoAI = "pipeline-no-ai"
    case pipelineNoBoost = "pipeline-no-boost"
    case pipeline = "pipeline"

    static let defaultSet: [EngineID] = [.parakeetV2, .parakeetV3, .appleSpeech, .appleDictation]

    func makeEngine() -> SpeechEngine {
        switch self {
        case .parakeetV2: return ParakeetEngine(id: self, version: .v2)
        case .parakeetV3: return ParakeetEngine(id: self, version: .v3)
        case .phonon2: return ParakeetEngine(id: self, version: .phonon2)
        case .ultra: return ParakeetEngine(id: self, version: .ultra)
        case .appleSpeech: return AppleEngine(id: self, kind: .speech)
        case .appleDictation: return AppleEngine(id: self, kind: .dictation)
        case .pipelineNoAI: return PipelineEngine(id: self, options: .init(boostWordList: true, aiReview: false))
        case .pipelineNoBoost: return PipelineEngine(id: self, options: .init(boostWordList: false, aiReview: true))
        case .pipeline: return PipelineEngine(id: self, options: .init(boostWordList: true, aiReview: true))
        }
    }
}

enum EngineError: Error, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

protocol SpeechEngine: AnyObject {
    var id: EngineID { get }
    /// Download (first run only) and load the model. Not included in per-clip timings.
    func prepare() async throws
    /// Transcribe one audio file. Timed by the caller.
    func transcribe(_ audio: URL) async throws -> String
}

/// NVIDIA Parakeet TDT via FluidAudio (Core ML, runs on the Neural Engine).
final class ParakeetEngine: SpeechEngine {
    let id: EngineID
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(id: EngineID, version: AsrModelVersion) {
        self.id = id
        self.version = version
    }

    func prepare() async throws {
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> String {
        guard let manager else { throw EngineError.unavailable("\(id.rawValue) not prepared") }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}

/// Exactly what the app types: the shared DictationCore pipeline, using the app's word list.
final class PipelineEngine: SpeechEngine {
    let id: EngineID
    private let options: DictationPipeline.Options
    private let pipeline = DictationPipeline()
    private let converter = AudioConverter()

    init(id: EngineID, options: DictationPipeline.Options) {
        self.id = id
        self.options = options
    }

    func prepare() async throws {
        try await pipeline.load(options: options)
        if options.aiReview, let reason = pipeline.reviewer.unavailableReason {
            print("  note: AI review skipped — \(reason)")
        }
    }

    func transcribe(_ audio: URL) async throws -> String {
        let samples = try converter.resampleAudioFile(audio)
        let stages = try await pipeline.transcribe(samples, options: options)
        return await pipeline.review(stages, options: options).final
    }
}

/// Apple's built-in on-device recognizers (macOS 26 SpeechAnalyzer).
/// `.speech` = SpeechTranscriber (newer model); `.dictation` = DictationTranscriber (system dictation model).
final class AppleEngine: SpeechEngine {
    enum Kind { case speech, dictation }

    let id: EngineID
    private let kind: Kind
    private var locale = Locale(identifier: "en-US")

    init(id: EngineID, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    func prepare() async throws {
        let wanted = Locale(identifier: "en-US")
        let supported: Locale?
        switch kind {
        case .speech:
            guard SpeechTranscriber.isAvailable else {
                throw EngineError.unavailable("SpeechTranscriber is not available on this Mac")
            }
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        case .dictation:
            supported = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        }
        guard let supported else { throw EngineError.unavailable("en-US is not supported by \(id.rawValue)") }
        locale = supported

        let module = makeModule()
        if await AssetInventory.status(forModules: [module]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("  downloading Apple's on-device English model (one time)…")
            try await request.downloadAndInstall()
        }
    }

    func transcribe(_ audio: URL) async throws -> String {
        let file = try AVAudioFile(forReading: audio)
        let module = makeModule()
        // Start reading results before analysis begins so nothing is missed.
        let collector = Task { () throws -> [String] in
            var phrases: [String] = []
            switch module {
            case let transcriber as SpeechTranscriber:
                for try await result in transcriber.results {
                    phrases.append(String(result.text.characters))
                }
            case let transcriber as DictationTranscriber:
                for try await result in transcriber.results {
                    phrases.append(String(result.text.characters))
                }
            default:
                break
            }
            return phrases
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [module], finishAfterFile: true)
        let phrases = try await collector.value
        withExtendedLifetime(analyzer) {}
        return phrases
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func makeModule() -> any SpeechModule {
        switch kind {
        case .speech:
            return SpeechTranscriber(locale: locale, preset: .transcription)
        case .dictation:
            return DictationTranscriber(locale: locale, preset: .longDictation)
        }
    }
}
