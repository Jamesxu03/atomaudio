import Foundation

/// Word error rate helpers.
///
/// Two views of the same comparison:
/// - `normalizedWords` ignores case and punctuation — "did the engine hear the right words?"
/// - `formattedWords` keeps case and punctuation — "could this be pasted as-is?"
enum WordErrorRate {
    static func normalizedWords(_ text: String) -> [String] {
        let t = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "%", with: " percent ")
            .replacingOccurrences(of: "&", with: " and ")
            // "15th" == "15": ordinal suffixes are formatting, not hearing.
            .replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
            // Thousands separators vanish ("1,249" == "1249"); "3.30" splits like "3:30".
            .replacingOccurrences(of: #"(\d),(\d)"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1 $2", options: .regularExpression)
            // Remaining dots join abbreviations ("p.m." == "pm").
            .replacingOccurrences(of: ".", with: "")
        let spaced = String(t.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " })
        let words = spaced
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
        return combiningSpelledNumbers(words)
    }

    /// "ten" == "10" and "twenty-five" == "25": engines differ on spelling out numbers,
    /// which isn't a hearing error.
    private static func combiningSpelledNumbers(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if let tens = tensWords[word] {
                if index + 1 < words.count, let unit = Int(numberWords[words[index + 1]] ?? ""), (1...9).contains(unit) {
                    result.append(String(tens + unit))
                    index += 2
                    continue
                }
                result.append(String(tens))
            } else {
                result.append(numberWords[word] ?? word)
            }
            index += 1
        }
        return result
    }

    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
        "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16",
        "seventeen": "17", "eighteen": "18", "nineteen": "19",
    ]

    static func formattedWords(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Minimum substitutions + insertions + deletions to turn `hypothesis` into `reference`.
    static func editDistance(_ reference: [String], _ hypothesis: [String]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }
        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        for i in 1...reference.count {
            current[0] = i
            for j in 1...hypothesis.count {
                let substitution = previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }
}
