import Foundation

/// Everything between "audio captured" and "text to type", shared by the app and the benchmark:
///
///     audio → Parakeet → word-list boosting → cleanup rules → on-device AI review → text
public final class DictationPipeline {
    public struct Options: Sendable {
        public var boostWordList: Bool
        public var aiReview: Bool

        public init(boostWordList: Bool = true, aiReview: Bool = true) {
            self.boostWordList = boostWordList
            self.aiReview = aiReview
        }
    }

    /// Every stage's output, for debugging and benchmarking.
    public struct Stages: Sendable {
        public var recognized = ""
        public var boosted = ""
        public var cleaned = ""
        public var reviewed = ""
        /// nil when the review didn't run.
        public var reviewAccepted: Bool?

        public var final: String { reviewed.isEmpty ? cleaned : reviewed }
    }

    public let reviewer = AIReviewer()
    public private(set) var vocabulary = Vocabulary.empty

    private let recognizer = SpeechRecognizer()
    private let booster = VocabularyBooster()
    private let vocabularyURL: URL
    private var vocabularyModified: Date?
    private var boosterReady = false
    /// Set when the boosting model couldn't load (e.g. offline on first run); retried only
    /// after the word list changes, so dictation never waits on a download that keeps failing.
    private var boosterFailed = false

    public init(vocabularyURL: URL = Vocabulary.defaultURL) {
        self.vocabularyURL = vocabularyURL
    }

    /// Loads Parakeet (required) and the boosting model (optional: its failure only disables boosting).
    public func load(options: Options) async throws {
        try await recognizer.load()
        try? Vocabulary.createDefaultFileIfMissing(at: vocabularyURL)
        await reloadVocabularyIfChanged(boosting: options.boostWordList)
        if options.aiReview { reviewer.prewarm(vocabulary: vocabulary) }
    }

    /// Step 1 (the "Transcribing…" part): speech → text, plus word-list boosting.
    public func transcribe(_ samples: [Float], options: Options) async throws -> Stages {
        await reloadVocabularyIfChanged(boosting: options.boostWordList)
        var stages = Stages()
        let recognition = try await recognizer.recognize(samples)
        stages.recognized = recognition.text
        stages.boosted = options.boostWordList && boosterReady
            ? await booster.apply(to: recognition)
            : recognition.text
        stages.cleaned = TextCleanup.apply(stages.boosted, vocabulary: vocabulary)
        return stages
    }

    /// Step 2 (the "Reviewing…" part): on-device AI proofreading, kept only if it stays faithful.
    public func review(_ stages: Stages, options: Options) async -> Stages {
        guard options.aiReview, !stages.cleaned.isEmpty, reviewer.unavailableReason == nil else { return stages }
        var stages = stages
        let outcome = await reviewer.review(stages.cleaned, vocabulary: vocabulary)
        stages.reviewed = outcome.text
        stages.reviewAccepted = outcome.accepted
        return stages
    }

    /// Picks up edits to the word list file before each dictation.
    private func reloadVocabularyIfChanged(boosting: Bool) async {
        let modified = (try? FileManager.default.attributesOfItem(atPath: vocabularyURL.path))?[.modificationDate] as? Date
        let fileChanged = modified != vocabularyModified
        let needsBooster = boosting && !boosterReady && !boosterFailed
        guard fileChanged || needsBooster else { return }
        vocabularyModified = modified
        vocabulary = (try? Vocabulary.load(from: vocabularyURL)) ?? .empty
        if boosting {
            do {
                try await booster.prepare(vocabulary)
                boosterReady = true
                boosterFailed = false
            } catch {
                boosterReady = false
                boosterFailed = true
            }
        }
    }
}
