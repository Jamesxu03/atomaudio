import Foundation

/// The user's word list: terms to spell exactly (UI, IPO, GitHub…), each with optional
/// "misheard as" aliases. One file feeds all three fixes: acoustic boosting, cleanup rules,
/// and the on-device AI review.
///
/// File format, one term per line (compatible with FluidAudio's simple vocabulary format):
///
///     UI: you eye, u i
///     Kubernetes
public struct Vocabulary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let term: String
        public let aliases: [String]
    }

    public var entries: [Entry]

    public var terms: [String] { entries.map(\.term) }

    public static let empty = Vocabulary(entries: [])

    public static func parse(_ contents: String) -> Vocabulary {
        var entries: [Entry] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            let term = parts[0].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            entries.append(Entry(term: term, aliases: aliases))
        }
        return Vocabulary(entries: entries)
    }

    public static func load(from url: URL) throws -> Vocabulary {
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    /// ~/Library/Application Support/Audio Input/vocabulary.txt
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio Input", isDirectory: true)
            .appendingPathComponent("vocabulary.txt")
    }

    /// Writes the starter list the first time, so there's a file to edit.
    public static func createDefaultFileIfMissing(at url: URL = defaultURL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try starterContents.write(to: url, atomically: true, encoding: .utf8)
    }

    public static let starterContents = """
        # Audio Input word list: words you want spelled exactly this way.
        # One term per line. After a colon, list what the recognizer mishears it as:
        #     UI: you eye, u i
        # Terms that are also everyday words (like "IT" or "US") will be capitalized everywhere.
        # Changes apply to your next dictation.

        # General
        UI: you eye
        UX
        AI
        API
        IPO
        PDF
        CEO
        Q&A
        GitHub
        Kubernetes

        # IP scouting: deals and agreements
        DD
        NDA
        CDA
        MTA
        MOU
        LOI
        SRA
        JDA
        CRADA
        ROFR
        ROFN
        TTO
        KOL
        POC

        # IP scouting: patents
        IP
        IPR
        FTO
        PCT
        PPA
        CIP
        RCE
        IDS
        OA
        NPE
        SEP
        FRAND
        PPH
        CPC
        IPC
        EPO
        USPTO
        WIPO
        CNIPA
        JPO
        KIPO
        PTAB

        # IP scouting: technology and market
        TRL
        MVP
        R&D
        SOTA
        OEM
        B2B
        SaaS
        TAM
        CAGR

        # IP scouting: investment
        VC
        CVC
        M&A
        ROI
        KPI
        ARR
        IRR
        NPV
        DCF
        EBITDA
        ESOP
        SPV
        AUM
        LP
        GP

        # Life sciences
        FDA
        CRO
        CDMO
        GMP

        # Left out on purpose because they're everyday words or names and would be
        # capitalized everywhere: SAFE (the note), SAM/SOM (market size), SPA, US.
        """
}
