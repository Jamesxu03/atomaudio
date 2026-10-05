import AppKit

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
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
