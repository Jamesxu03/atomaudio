import DictationCore
import FluidAudio
import Foundation

/// `Bench --confidence`: are the words Parakeet gets wrong the ones it was unsure about?
///
/// Labels every recognized word right or wrong against the reference, then shows how well a
/// confidence cutoff separates the two. That decides whether flagging low-confidence words to the
/// AI review can work, and at which cutoff.
enum ConfidenceReport {
    struct LabeledWord {
        let clip: String
        let word: RecognizedWord
        let wrong: Bool
        /// The reference word it was aligned to; nil when Parakeet inserted a word that wasn't said.
        let said: String?
    }

    static let cutoffs: [Float] = [0.3, 0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 0.98]

    static func run(clips: [Clip], outputDirectory: URL) async throws {
        print("Loading Parakeet v2…")
        let recognizer = SpeechRecognizer()
        try await recognizer.load()
        let converter = AudioConverter()

        var labeled: [LabeledWord] = []
        var missed = 0
        for clip in clips {
            let recognition = try await recognizer.recognize(try converter.resampleAudioFile(clip.audio))
            let result = label(recognition.words, against: clip.reference, clip: clip.name)
            labeled += result.words
            missed += result.missed
        }

        let report = render(labeled, missed: missed, clipCount: clips.count)
        print("\n" + report)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let url = outputDirectory.appendingPathComponent("confidence-\(stamp.replacingOccurrences(of: ":", with: "")).md")
        try ("# Word confidence — \(stamp)\n\n" + report).write(to: url, atomically: true, encoding: .utf8)
        print("Saved: \(url.path)")
    }

    /// A recognized word is wrong if any part of it was substituted or inserted. Words that were said
    /// but not recognized at all ("missed") can't carry a confidence, so they're only counted.
    static func label(_ words: [RecognizedWord], against reference: String, clip: String)
        -> (words: [LabeledWord], missed: Int)
    {
        // Normalize each word on its own (so "ten" == "10", "p.m." == "pm") and remember its owner.
        var pieces: [String] = []
        var owners: [Int] = []
        for (index, word) in words.enumerated() {
            for piece in WordErrorRate.normalizedWords(word.text) {
                pieces.append(piece)
                owners.append(index)
            }
        }
        let referenceWords = WordErrorRate.normalizedWords(reference)
        let alignment = align(referenceWords, pieces)

        var wrong = [Bool](repeating: false, count: words.count)
        var said = [String?](repeating: nil, count: words.count)
        var hasPieces = [Bool](repeating: false, count: words.count)
        for (piece, owner) in owners.enumerated() {
            hasPieces[owner] = true
            if !alignment.matches[piece].matched { wrong[owner] = true }
            if said[owner] == nil { said[owner] = alignment.matches[piece].said }
        }
        let labeled = words.indices.filter { hasPieces[$0] }.map {
            LabeledWord(clip: clip, word: words[$0], wrong: wrong[$0], said: said[$0])
        }
        return (labeled, alignment.missed)
    }

    /// Levenshtein alignment with backtrace: for each hypothesis word, whether it matched and which
    /// reference word it lined up with, plus how many reference words were dropped.
    static func align(_ reference: [String], _ hypothesis: [String])
        -> (matches: [(matched: Bool, said: String?)], missed: Int)
    {
        let n = reference.count, m = hypothesis.count
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitution = cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                    cost[i][j] = min(substitution, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var matches = [(matched: Bool, said: String?)](repeating: (false, nil), count: m)
        var missed = 0
        var i = n, j = m
        while j > 0 {
            let same = i > 0 && reference[i - 1] == hypothesis[j - 1]
            if i > 0, cost[i][j] == cost[i - 1][j - 1] + (same ? 0 : 1) {
                matches[j - 1] = (same, reference[i - 1])
                i -= 1
                j -= 1
            } else if cost[i][j] == cost[i][j - 1] + 1 {
                j -= 1
            } else {
                missed += 1
                i -= 1
            }
        }
        return (matches, missed + i)
    }

    static func render(_ words: [LabeledWord], missed: Int, clipCount: Int) -> String {
        let wrong = words.filter(\.wrong)
        var lines = [
            "\(clipCount) clips, \(words.count) recognized words: \(wrong.count) wrong, plus \(missed) said but not recognized at all.",
            "",
            "| Flag words below | Words flagged | …of which wrong | Wrong words caught |",
            "|---|---|---|---|",
        ]
        for cutoff in cutoffs {
            let flagged = words.filter { $0.word.confidence < cutoff }
            let flaggedWrong = flagged.filter(\.wrong).count
            lines.append(String(
                format: "| %.2f | %d (%.0f%% of all) | %d (%.0f%%) | %d of %d (%.0f%%) |",
                cutoff, flagged.count, percent(flagged.count, words.count), flaggedWrong,
                percent(flaggedWrong, flagged.count), flaggedWrong, wrong.count, percent(flaggedWrong, wrong.count)))
        }

        lines += ["", "**Every wrong word**, least confident first:", ""]
        for item in wrong.sorted(by: { $0.word.confidence < $1.word.confidence }) {
            let said = item.said.map { "said \"\($0)\"" } ?? "nothing said"
            lines.append(String(format: "- %.2f  \"%@\" (%@) — %@", item.word.confidence, item.word.text, said, item.clip))
        }

        lines += ["", "**Least confident correct words** (what flagging would also catch):", ""]
        for item in words.filter({ !$0.wrong }).sorted(by: { $0.word.confidence < $1.word.confidence }).prefix(15) {
            lines.append(String(format: "- %.2f  \"%@\" — %@", item.word.confidence, item.word.text, item.clip))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func percent(_ part: Int, _ whole: Int) -> Double {
        whole > 0 ? 100 * Double(part) / Double(whole) : 0
    }
}
