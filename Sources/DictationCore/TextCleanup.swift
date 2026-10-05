import Foundation

/// Fast, predictable fixes applied to every transcript (no AI involved).
public enum TextCleanup {
    public static func apply(_ text: String, vocabulary: Vocabulary) -> String {
        var result = replacingUnknownTokens(in: text)
        result = removingFillers(from: result)
        for entry in vocabulary.entries {
            result = applyingAliases(of: entry, to: result)
            result = joiningSpelledLetters(of: entry.term, in: result)
            result = applyingCasing(of: entry.term, to: result)
        }
        return joiningSlashedAcronyms(in: tidyingSpaces(in: result))
    }

    /// "DD slash NDA" / "DD / NDA" → "DD/NDA". Only between all-caps acronyms, so the
    /// word "slash" in ordinary sentences is left alone.
    static func joiningSlashedAcronyms(in text: String) -> String {
        let acronym = #"[A-Z][A-Z0-9&]*[A-Z0-9]"#
        // Only separators that still need fixing, so an already-tight "DD/NDA" doesn't consume
        // "NDA" before the next link of a chain can match.
        let separator = #"(?:\s+(?i:slash)\s+|\s+/\s*|/\s+)"#
        let pattern = #"\b("# + acronym + ")" + separator + "(" + acronym + #")\b"#
        var result = text
        // Repeat for chains like "DD slash NDA slash MTA".
        for _ in 0..<3 {
            let next = result.replacingOccurrences(of: pattern, with: "$1/$2", options: .regularExpression)
            if next == result { break }
            result = next
        }
        return result
    }

    /// Parakeet emits `<unk>` for symbols outside its vocabulary. Between letters it's almost
    /// always "&" (Q&A, R&D, AT&T); anywhere else it's dropped.
    static func replacingUnknownTokens(in text: String) -> String {
        text.replacingOccurrences(of: #"(?<=[A-Za-z])<unk>(?=[A-Za-z])"#, with: "&", options: .regularExpression)
            .replacingOccurrences(of: "<unk>", with: "")
    }

    static func removingFillers(from text: String) -> String {
        let removed = text.replacingOccurrences(
            of: #"(?i)\b(?:u+m+|u+h+|uhm|erm|hmm+)\b[,.]?\s*"#, with: "", options: .regularExpression)
        guard removed != text else { return text }
        return capitalizingSentenceStarts(in: removed)
    }

    /// "you eye" → "UI" when the user listed that alias.
    static func applyingAliases(of entry: Vocabulary.Entry, to text: String) -> String {
        entry.aliases.reduce(text) { result, alias in
            result.replacingOccurrences(
                of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: alias) + #"\b"#,
                with: NSRegularExpression.escapedTemplate(for: entry.term),
                options: .regularExpression)
        }
    }

    /// "I P O" / "I. P. O." → "IPO", only for acronyms on the word list. Letters must be
    /// capitals so the article "a" in "a I…" is never swallowed.
    static func joiningSpelledLetters(of term: String, in text: String) -> String {
        let letters = Array(term)
        guard (2...6).contains(letters.count), letters.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return text }
        let pattern = #"\b"# + letters.map(String.init).joined(separator: #"\.?\s+"#) + #"\b\.?"#
        return text.replacingOccurrences(
            of: pattern, with: NSRegularExpression.escapedTemplate(for: term), options: .regularExpression)
    }

    /// "github" → "GitHub", "ipo" → "IPO". Skipped for everyday two-letter words ("it", "us")
    /// so an acronym like IT doesn't capitalize every "it".
    static func applyingCasing(of term: String, to text: String) -> String {
        guard term != term.lowercased(), !commonShortWords.contains(term.lowercased()) else { return text }
        return text.replacingOccurrences(
            of: #"(?i)(?<![\w&])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\w&])"#,
            with: NSRegularExpression.escapedTemplate(for: term),
            options: .regularExpression)
    }

    static func tidyingSpaces(in text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizingSentenceStarts(in text: String) -> String {
        var characters = Array(text)
        var atSentenceStart = true
        for index in characters.indices {
            let character = characters[index]
            if atSentenceStart, character.isLetter {
                characters[index] = Character(character.uppercased())
                atSentenceStart = false
            } else if ".!?".contains(character) {
                atSentenceStart = true
            } else if !character.isWhitespace {
                atSentenceStart = false
            }
        }
        return String(characters)
    }

    private static let commonShortWords: Set<String> = [
        "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it", "me",
        "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we",
    ]
}
