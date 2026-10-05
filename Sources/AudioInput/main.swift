import AppKit
import DictationCore

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    // Packaging check, run by Scripts/make_dmg.sh: load the speech model exactly as the app does
    // and transcribe a file, then exit. Prints where the model came from.
    if let index = arguments.firstIndex(of: "--check-models") {
        let file = index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
        Task {
            do {
                let recognizer = SpeechRecognizer()
                let start = Date()
                try await recognizer.load()
                print(String(format: "Model loaded from %@ in %.1f s", recognizer.modelSource, Date().timeIntervalSince(start)))
                if let file { print("Heard: \(try await recognizer.recognize(fileAt: file).text)") }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
    // Developer tools: render the design to PNGs without launching the app.
    let renderers: [String: (URL) throws -> Void] = [
        "--render-overlay-previews": SpeakingOverlay.renderPreviews,
        "--render-app-iconset": Brand.writeIconset,
    ]
    for (flag, render) in renderers {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { continue }
        do {
            try render(URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar only: no Dock icon, never steals focus from the app you're typing in.
    app.setActivationPolicy(.accessory)
    app.run()
}
