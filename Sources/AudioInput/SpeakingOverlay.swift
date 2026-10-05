import AppKit
import SwiftUI

/// Floating pill at the bottom-center of the screen: a coral ring of dots and a live level meter
/// while Right ⌥ is held, then "Transcribing…" / "Reviewing…", and short notices. It never takes
/// focus, so the text still lands in the app you were typing in. Follows light/dark mode.
@MainActor
final class SpeakingOverlay {
    /// Matches how often the microphone delivers audio (~2048 frames at 48 kHz), so each bar is new sound.
    private static let meterInterval: TimeInterval = 1.0 / 24
    private static let noticeDuration: TimeInterval = 1.8

    private let model = OverlayModel()
    private let panel: OverlayPanel
    private let levelSource: @MainActor () -> Float
    private var meterTimer: Timer?
    private var isShown = false
    private var noticeGeneration = 0

    init(levelSource: @escaping @MainActor () -> Float) {
        self.levelSource = levelSource
        let hostingView = NSHostingView(rootView: OverlayView(model: model))
        hostingView.sizingOptions = []
        panel = OverlayPanel(content: hostingView)
    }

    func update(for state: DictationController.State) {
        switch state {
        case .recording:
            show(.listening)
        case .transcribing:
            show(.working("Transcribing…"))
        case .reviewing:
            show(.working("Reviewing…"))
        case .ready, .loadingModel, .failed:
            // A notice hides itself once it has been read.
            if case .notice = model.phase { return }
            hide()
        }
    }

    func showNotice(_ text: String) {
        show(.notice(text))
        noticeGeneration += 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration) { [weak self] in
            guard let self, self.noticeGeneration == generation, case .notice = self.model.phase else { return }
            self.hide()
        }
    }

    private func show(_ phase: OverlayModel.Phase) {
        model.phase = phase
        if phase == .listening { startMeter() } else { stopMeter() }
        guard !isShown else { return }
        isShown = true
        placeOnActiveScreen()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        stopMeter()
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Shown again while fading out: keep it up.
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
            self.model.phase = .hidden
        })
    }

    private func placeOnActiveScreen() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
    }

    private func startMeter() {
        guard meterTimer == nil else { return }
        model.levels = Array(repeating: 0, count: OverlayModel.barCount)
        let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.model.push(Self.barHeight(forRMS: self.levelSource()))
            }
        }
        // .common keeps the meter moving even while the menu-bar menu is open.
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    /// Tuned for quiet speech: room noise (about −55 dBFS) reads as flat, −25 dBFS fills the bar.
    private static func barHeight(forRMS rms: Float) -> CGFloat {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return CGFloat(min(max((decibels + 55) / 30, 0), 1))
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening
        case working(String)
        case notice(String)
    }

    static let barCount = 18

    @Published var phase: Phase = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: barCount)

    /// Newest level enters on the right, so the meter scrolls like a waveform.
    func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: 42)
            .background(Capsule().fill(colorScheme == .dark ? Color(white: 0.13) : .white))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07), lineWidth: 1))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.16), radius: 12, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 12) {
                DotRing(mode: .listening(level: model.levels.last ?? 0))
                LevelMeter(levels: model.levels)
            }
        case .working(let label):
            HStack(spacing: 10) {
                DotRing(mode: .spinning)
                Text(label)
            }
        case .notice(let text):
            HStack(spacing: 10) {
                DotRing(mode: .still)
                Text(text)
            }
        case .hidden:
            EmptyView()
        }
    }
}

/// The brand mark, alive: dots swell with your voice while listening, and a highlight
/// chases around the ring while working.
private struct DotRing: View {
    enum Mode: Equatable {
        case listening(level: CGFloat)
        case spinning
        case still
    }

    let mode: Mode

    var body: some View {
        TimelineView(.animation(paused: mode != .spinning)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let lead = timeline.date.timeIntervalSinceReferenceDate * 10  // dots per second
                for (index, dot) in Brand.ringDotCenters(center: center, radius: 8.5, flipped: true).enumerated() {
                    var radius: CGFloat = 1.9
                    var opacity: CGFloat = 1
                    switch mode {
                    case .listening(let level):
                        // Alternate dots swell slightly differently so the ring ripples.
                        radius += level * (index.isMultiple(of: 2) ? 1.4 : 0.9)
                    case .spinning:
                        let behind = (lead - Double(index)).truncatingRemainder(dividingBy: Double(Brand.ringDotCount))
                        let age = behind < 0 ? behind + Double(Brand.ringDotCount) : behind
                        opacity = 0.2 + 0.8 * CGFloat(1 - age / Double(Brand.ringDotCount))
                    case .still:
                        break
                    }
                    let rect = CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Brand.coralColor.opacity(opacity)))
                }
                let core: CGFloat = mode == .still ? 2.6 : 3.2
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
                    with: .color(Brand.coralColor))
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// Dots at silence that stretch into pills as you speak.
private struct LevelMeter: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Brand.coralColor.opacity(0.35 + 0.65 * level))
                    .frame(width: 4, height: 4 + level * 18)
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// Borderless, click-through, never key: shows on every Space and over full-screen apps.
private final class OverlayPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        alphaValue = 0
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension SpeakingOverlay {
    /// Renders each overlay state (light and dark) to PNG, to check the design without a live mic:
    /// `AudioInput --render-overlay-previews <dir>`
    static func renderPreviews(to directory: URL) throws {
        let phases: [(String, OverlayModel.Phase)] = [
            ("listening", .listening),
            ("transcribing", .working("Transcribing…")),
            ("reviewing", .working("Reviewing…")),
            ("notice", .notice("Didn't catch that")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, phase) in phases {
                let model = OverlayModel()
                model.phase = phase
                model.levels = (0..<OverlayModel.barCount).map { CGFloat(abs(sin(Double($0) * 0.55))) * 0.85 }
                let view = OverlayView(model: model)
                    .frame(width: 360, height: 64)
                    .background(scheme == .dark ? Color(white: 0.25) : Color(white: 0.93))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { continue }
                try png.write(to: directory.appendingPathComponent("overlay-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
        // Menu-bar icons side by side at 4×: idle, loading, recording, working.
        let styles: [Brand.MenuBarStyle] = [.idle, .loading, .recording, .working]
        let strip = NSImage(size: NSSize(width: 26 * styles.count, height: 26), flipped: false) { _ in
            NSColor(white: 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 26 * styles.count, height: 26).fill()
            for (index, style) in styles.enumerated() {
                Brand.menuBarIcon(style).draw(in: NSRect(x: 26 * index + 4, y: 4, width: 18, height: 18))
            }
            return true
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 26 * styles.count * 4, pixelsHigh: 104, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = strip.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        strip.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menubar-icons.png"))
    }
}
