import AppKit
import AVFoundation
import DictationCore
import os

/// Hold → record, release → transcribe → review → type into the focused app.
@MainActor
final class DictationController {
    enum State: Equatable {
        case loadingModel
        case ready
        case recording
        case transcribing
        case reviewing
        case failed(String)
    }

    /// Shorter holds are accidental taps of the dictation key, not dictation.
    private static let minimumHold: TimeInterval = 0.3
    /// Keep listening briefly after release so the last word isn't clipped.
    private static let releaseTail: Duration = .milliseconds(150)
    private static let aiReviewKey = "aiReview"

    var onChange: (() -> Void)?
    /// Short, transient messages for the on-screen overlay ("Didn't catch that").
    var onNotice: ((String) -> Void)?
    private(set) var state: State = .loadingModel { didSet { onChange?() } }
    private(set) var lastTranscript: String? { didSet { onChange?() } }
    private(set) var lastError: String? { didSet { onChange?() } }

    /// Proofread each dictation with Apple's on-device model before typing it. On by default:
    /// on the user's clips it cut the punctuation-aware error rate from 13.1% to 9.1%.
    var aiReview: Bool {
        get { UserDefaults.standard.bool(forKey: Self.aiReviewKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.aiReviewKey)
            if newValue { pipeline.reviewer.prewarm(vocabulary: pipeline.vocabulary) }
            onChange?()
        }
    }

    /// Why the AI review can't run on this Mac right now, or nil.
    var aiReviewUnavailableReason: String? { pipeline.reviewer.unavailableReason }

    /// Current microphone loudness while recording (RMS, 0...1 linear).
    var inputLevel: Float { recorder.level }

    private let recorder = AudioRecorder()
    private let pipeline = DictationPipeline()
    private let inserter = TextInserter()
    private let logger = Logger(subsystem: "local.audioinput", category: "dictation")
    private var recordingStartedAt = Date()

    /// Acoustic word-list boosting stays off: with the ~70-term IP-scouting list it swapped ordinary
    /// words for acronyms ("team" → TAM, "slash" → SaaS) and raised WER on the user's clips from
    /// 7.3% to 9.3%. The word list still drives the cleanup rules and the AI review.
    private var options: DictationPipeline.Options {
        DictationPipeline.Options(boostWordList: false, aiReview: aiReview)
    }

    init() {
        UserDefaults.standard.register(defaults: [Self.aiReviewKey: true])
    }

    func loadModel() {
        state = .loadingModel
        Task {
            let start = Date()
            do {
                try await pipeline.load(options: options)
                logger.info("""
                    model ready in \(Date().timeIntervalSince(start), format: .fixed(precision: 2)) s \
                    from \(self.pipeline.modelSource, privacy: .public)
                    """)
                state = .ready
            } catch {
                logger.error("model load failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("Couldn't load the speech model: \(error.localizedDescription)")
            }
        }
    }

    func beginRecording() {
        guard state == .ready else {
            if state == .loadingModel { onNotice?("Speech model still loading…") }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onNotice?("Microphone access needed — see menu bar")
            return
        }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            lastError = nil
            state = .recording
            play("Tink")
        } catch {
            logger.error("mic start failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Microphone error: \(error.localizedDescription)"
            onNotice?("Microphone unavailable")
        }
    }

    func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        state = .ready
    }

    func finishRecording() {
        guard state == .recording else { return }
        guard Date().timeIntervalSince(recordingStartedAt) >= Self.minimumHold else {
            cancelRecording()
            return
        }
        state = .transcribing
        Task {
            try? await Task.sleep(for: Self.releaseTail)
            let samples = recorder.stop()
            play("Pop")
            let start = Date()
            let options = self.options
            // Read the text before the cursor while Parakeet runs; only the AI review uses it.
            let contextTask = options.aiReview ? Task.detached { FocusedTextContext.read() } : nil
            do {
                var stages = try await pipeline.transcribe(samples, options: options)
                let transcribed = Date()
                var contextLength = 0
                if options.aiReview, !stages.cleaned.isEmpty, aiReviewUnavailableReason == nil {
                    state = .reviewing
                    let context = await contextTask?.value
                    contextLength = context?.count ?? 0
                    stages = await pipeline.review(stages, options: options, context: context)
                }
                // Log timings and sizes only — never what was said.
                logger.info("""
                    \(Double(samples.count) / SpeechRecognizer.sampleRate, format: .fixed(precision: 1)) s audio: \
                    transcribed in \(transcribed.timeIntervalSince(start), format: .fixed(precision: 2)) s, \
                    reviewed in \(Date().timeIntervalSince(transcribed), format: .fixed(precision: 2)) s \
                    (accepted: \(String(describing: stages.reviewAccepted), privacy: .public), \
                    \(stages.uncertainWords.count) unsure words, \(contextLength) chars of context), \
                    \(stages.final.count) chars
                    """)
                let text = stages.final
                if text.isEmpty {
                    onNotice?("Didn't catch that")
                } else {
                    lastTranscript = text
                    // Trailing space so back-to-back dictations don't run together.
                    inserter.insert(text + " ")
                }
            } catch {
                logger.error("transcription failed: \(error.localizedDescription, privacy: .public)")
                lastError = "Transcription failed: \(error.localizedDescription)"
                onNotice?("Transcription failed")
            }
            state = .ready
        }
    }

    private func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
