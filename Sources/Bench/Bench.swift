import AVFoundation
import Foundation

struct Clip {
    let name: String
    let audio: URL
    let reference: String
    let duration: Double

    static let audioExtensions: Set<String> = ["wav", "caf", "aif", "aiff", "m4a", "mp3"]

    /// Every audio file in `directory` that has a same-named .txt holding exactly what was said.
    static func load(from directory: URL) throws -> [Clip] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var clips: [Clip] = []
        for audio in files where audioExtensions.contains(audio.pathExtension.lowercased()) {
            let referenceURL = audio.deletingPathExtension().appendingPathExtension("txt")
            guard let reference = try? String(contentsOf: referenceURL, encoding: .utf8) else {
                print("  ! skipping \(audio.lastPathComponent): no matching .txt reference")
                continue
            }
            let file = try AVAudioFile(forReading: audio)
            clips.append(Clip(
                name: audio.deletingPathExtension().lastPathComponent,
                audio: audio,
                reference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                duration: Double(file.length) / file.fileFormat.sampleRate
            ))
        }
        return clips
    }
}

struct ClipResult {
    let clip: Clip
    let hypothesis: String
    let seconds: Double
    let wordErrors: Int
    let referenceWords: Int
    let formattedErrors: Int
    let formattedReferenceWords: Int
}

struct EngineSummary {
    let id: EngineID
    let loadSeconds: Double
    let results: [ClipResult]

    var wer: Double { ratio(results.map(\.wordErrors), results.map(\.referenceWords)) }
    var formattedWER: Double { ratio(results.map(\.formattedErrors), results.map(\.formattedReferenceWords)) }
    var averageLatency: Double { results.map(\.seconds).reduce(0, +) / Double(max(results.count, 1)) }
    var maxLatency: Double { results.map(\.seconds).max() ?? 0 }
    var speedFactor: Double {
        let audio = results.map(\.clip.duration).reduce(0, +)
        let compute = results.map(\.seconds).reduce(0, +)
        return compute > 0 ? audio / compute : 0
    }

    private func ratio(_ errors: [Int], _ words: [Int]) -> Double {
        let total = words.reduce(0, +)
        return total > 0 ? Double(errors.reduce(0, +)) / Double(total) : 0
    }
}

struct Options {
    var clipsDirectory = URL(fileURLWithPath: "TestClips/mine")
    var engines = EngineID.defaultSet
    var outputDirectory = URL(fileURLWithPath: "BenchResults")
    var confidence = false

    static let usage = """
        Usage: swift run -c release Bench [--clips DIR] [--engines LIST] [--out DIR] [--confidence]

          --clips DIR     Folder of audio files, each with a same-named .txt reference (default: TestClips/mine)
          --engines LIST  Comma-separated, from: \(EngineID.allCases.map(\.rawValue).joined(separator: ", "))
                          (default: \(EngineID.defaultSet.map(\.rawValue).joined(separator: ",")))
          --out DIR       Where the markdown report goes (default: BenchResults)
          --confidence    Instead of comparing engines, check whether Parakeet v2's wrong words are the
                          ones it was least confident about
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--clips":
                options.clipsDirectory = URL(fileURLWithPath: try value(after: argument, &iterator))
            case "--out":
                options.outputDirectory = URL(fileURLWithPath: try value(after: argument, &iterator))
            case "--engines":
                options.engines = try value(after: argument, &iterator).split(separator: ",").map { name in
                    guard let id = EngineID(rawValue: String(name)) else {
                        throw EngineError.unavailable("unknown engine '\(name)'\n\n\(usage)")
                    }
                    return id
                }
            case "--confidence":
                options.confidence = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw EngineError.unavailable("unknown argument '\(argument)'\n\n\(usage)")
            }
        }
        return options
    }

    private static func value(after flag: String, _ iterator: inout IndexingIterator<[String]>) throws -> String {
        guard let value = iterator.next() else { throw EngineError.unavailable("\(flag) needs a value") }
        return value
    }
}

@main
struct Bench {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        let clips = try Clip.load(from: options.clipsDirectory)
        guard let firstClip = clips.first else {
            throw EngineError.unavailable(
                "no clips in \(options.clipsDirectory.path). Record some with: swift run -c release RecordClips")
        }
        let totalWords = clips.map { WordErrorRate.normalizedWords($0.reference).count }.reduce(0, +)
        let totalAudio = clips.map(\.duration).reduce(0, +)
        print("Clips: \(clips.count) (\(String(format: "%.0f", totalAudio)) s of audio, \(totalWords) reference words)")
        if totalWords < 200 {
            print("  note: under ~200 words, a single mistake moves WER a lot — treat small gaps as ties.")
        }
        if options.confidence {
            return try await ConfidenceReport.run(clips: clips, outputDirectory: options.outputDirectory)
        }

        var summaries: [EngineSummary] = []
        for id in options.engines {
            let engine = id.makeEngine()
            print("\n▶ \(id.rawValue): loading (first run downloads the model)…")
            let loadStart = ContinuousClock.now
            do {
                try await engine.prepare()
            } catch {
                print("  skipped: \(error)")
                continue
            }
            let loadSeconds = seconds(since: loadStart)
            print(String(format: "  ready in %.1f s", loadSeconds))

            // The first call compiles/warms the model; the app would do this at launch, so don't time it.
            _ = try? await engine.transcribe(firstClip.audio)

            var results: [ClipResult] = []
            for clip in clips {
                let start = ContinuousClock.now
                let hypothesis: String
                do {
                    hypothesis = try await engine.transcribe(clip.audio)
                } catch {
                    print("  ! \(clip.name): \(error)")
                    hypothesis = ""
                }
                let elapsed = seconds(since: start)
                let reference = WordErrorRate.normalizedWords(clip.reference)
                let formattedReference = WordErrorRate.formattedWords(clip.reference)
                let result = ClipResult(
                    clip: clip,
                    hypothesis: hypothesis,
                    seconds: elapsed,
                    wordErrors: WordErrorRate.editDistance(reference, WordErrorRate.normalizedWords(hypothesis)),
                    referenceWords: reference.count,
                    formattedErrors: WordErrorRate.editDistance(
                        formattedReference, WordErrorRate.formattedWords(hypothesis)),
                    formattedReferenceWords: formattedReference.count
                )
                results.append(result)
                let marker = result.wordErrors == 0 ? "✓" : "✗"
                print(String(format: "  %@ %@  %d/%d words wrong  %.2f s", marker, clip.name,
                             result.wordErrors, result.referenceWords, elapsed))
            }
            summaries.append(EngineSummary(id: id, loadSeconds: loadSeconds, results: results))
        }

        guard !summaries.isEmpty else { throw EngineError.unavailable("no engine could run") }
        let table = summaryTable(summaries)
        print("\n" + table)
        let reportURL = try writeReport(summaries, table: table, clips: clips, to: options.outputDirectory)
        print("Full report with every mistake: \(reportURL.path)")
    }

    static func summaryTable(_ summaries: [EngineSummary]) -> String {
        var lines = [
            "| Engine | WER (words) | WER (with case + punctuation) | Avg latency | Worst latency | Speed vs real time | Load time |",
            "|---|---|---|---|---|---|---|",
        ]
        for s in summaries.sorted(by: { $0.wer < $1.wer }) {
            lines.append(String(format: "| %@ | %.1f%% | %.1f%% | %.2f s | %.2f s | %.0f× | %.1f s |",
                                s.id.rawValue, s.wer * 100, s.formattedWER * 100,
                                s.averageLatency, s.maxLatency, s.speedFactor, s.loadSeconds))
        }
        return lines.joined(separator: "\n")
    }

    static func writeReport(_ summaries: [EngineSummary], table: String, clips: [Clip], to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        var report = "# Engine benchmark — \(stamp)\n\n"
        report += "Clips: \(clips.count) on \(ProcessInfo.processInfo.hostName)\n\n\(table)\n\n"
        report += "WER (words) ignores case and punctuation. The second column counts a word wrong if its "
        report += "capitalization or punctuation differs, which is closer to what gets pasted.\n"
        for summary in summaries {
            report += "\n## \(summary.id.rawValue)\n"
            let misses = summary.results.filter { $0.wordErrors > 0 }
            if misses.isEmpty { report += "\nNo word errors.\n" }
            for result in misses {
                report += "\n**\(result.clip.name)** (\(result.wordErrors) wrong)\n\n"
                report += "- said:  \(result.clip.reference)\n- heard: \(result.hypothesis)\n"
            }
        }
        let url = directory.appendingPathComponent("bench-\(stamp.replacingOccurrences(of: ":", with: "")).md")
        try report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
