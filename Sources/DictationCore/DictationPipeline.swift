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
        /// Words Parakeet was unsure it heard right, passed to the review as the likeliest mistakes.
        public var uncertainWords: [String] = []
        /// nil when the review didn't run.
        public var reviewAccepted: Bool?

        public var final: String { reviewed.isEmpty ? cleaned : reviewed }
    }

    /// On the user's clips, 7 of Parakeet's 21 wrong words scored below 0.7 while only 9% of all
    /// words did; raising the cutoff to 0.85 flagged 16 more correct words and no more wrong ones.
    /// Measure with `Bench --confidence`.
    public static let uncertainBelow: Float = 0.7

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
        stages.uncertainWords = Self.uncertainWords(in: recognition.words)
        stages.boosted = options.boostWordList && boosterReady
            ? await booster.apply(to: recognition)
            : recognition.text
        stages.cleaned = TextCleanup.apply(stages.boosted, vocabulary: vocabulary)
        return stages
    }

    /// Step 2 (the "Reviewing…" part): on-device AI proofreading, kept only if it stays faithful.
    /// `context` is the text just before the cursor, so the review knows the topic.
    public func review(_ stages: Stages, options: Options, context: String? = nil) async -> Stages {
        guard options.aiReview, !stages.cleaned.isEmpty, reviewer.unavailableReason == nil else { return stages }
        var stages = stages
        let outcome = await reviewer.review(
            stages.cleaned, vocabulary: vocabulary, uncertainWords: stages.uncertainWords, context: context)
        stages.reviewed = outcome.text
        stages.reviewAccepted = outcome.accepted
        return stages
    }

    /// Low-confidence lowercase words without their punctuation, each listed once. Capitalized words
    /// (names, products, acronyms) are left out: a text-only review can't recover a name it never
    /// heard, and flagging "VS Code" made it expand to "Visual Studio Code". The mix-ups that context
    /// can fix are between everyday words: act/app, tabs/types, call/corps.
    public static func uncertainWords(in words: [RecognizedWord]) -> [String] {
        var seen = Set<String>()
        return words.filter { $0.confidence < uncertainBelow }
            .map { $0.text.trimmingCharacters(in: .punctuationCharacters) }
            .filter { word in
                guard let first = word.first, first.isLowercase else { return false }
                return seen.insert(word).inserted
            }
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
