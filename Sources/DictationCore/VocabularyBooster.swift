import FluidAudio
import Foundation

/// Acoustic word boosting: a small CTC model (Parakeet CTC 110M, ~100 MB, downloaded once)
/// listens for the word-list terms in the audio and corrects Parakeet's transcript where it
/// hears them. FluidAudio skips terms shorter than 3 characters (UI, AI); those are handled
/// by `TextCleanup` and the AI review instead.
public final class VocabularyBooster {
    private var models: CtcModels?
    private var session: VocabularyBoostingSession?

    public init() {}

    public func prepare(_ vocabulary: Vocabulary) async throws {
        let models: CtcModels
        if let loaded = self.models {
            models = loaded
        } else {
            models = try await CtcModels.downloadAndLoad()
            self.models = models
        }
        let terms = vocabulary.entries.map { entry in
            CustomVocabularyTerm(text: entry.term, aliases: entry.aliases.isEmpty ? nil : entry.aliases)
        }
        session = terms.isEmpty
            ? nil
            : try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: terms), ctcModels: models, config: Self.shortTermConfig)
    }

    /// The word list is short acronyms that sound like everyday English ("API" ≈ "a pie"). With
    /// FluidAudio's defaults that replaced ordinary words on the user's clips (7.6% → 67% WER), so
    /// use its documented short-vocabulary settings: no acoustic-only rescue, tapered boost.
    private static let shortTermConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        spotterRescueMinSimilarity: 0.30,
        spotterRescueMultiWordMinSimilarity: 0.50,
        spotterRescueEnabled: false
    )

    /// Never fails: without a session, or if the CTC pass errors, the transcript is returned unchanged.
    public func apply(to recognition: Recognition) async -> String {
        guard let session, !recognition.text.isEmpty else { return recognition.text }
        let output = await session.rescore(
            text: recognition.text,
            tokenTimings: recognition.tokenTimings,
            audioSamples: recognition.audio
        )
        return output?.text ?? recognition.text
    }
}
