import AppKit
import SwiftUI

/// Visual identity: coral (#FF5A6A) and a ring of dots, drawn in code so the menu-bar icon,
/// the overlay and the app icon always match.
enum Brand {
    static let coral = NSColor(srgbRed: 1.0, green: 90 / 255, blue: 106 / 255, alpha: 1)
    static let coralDeep = NSColor(srgbRed: 238 / 255, green: 64 / 255, blue: 84 / 255, alpha: 1)
    static let coralColor = Color(nsColor: coral)

    static let ringDotCount = 8

    /// Centers of the ring's dots, starting at 12 o'clock and going clockwise.
    static func ringDotCenters(center: CGPoint, radius: CGFloat, flipped: Bool = false) -> [CGPoint] {
        (0..<ringDotCount).map { index in
            let angle = Double(index) / Double(ringDotCount) * 2 * .pi
            let dy = radius * CGFloat(cos(angle))
            return CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: flipped ? center.y - dy : center.y + dy)
        }
    }

    // MARK: - Menu bar

    enum MenuBarStyle {
        case idle, loading, recording, working
    }

    /// 18-pt ring of dots around a center dot. Template (follows light/dark menu bar) except while
    /// recording, when it turns coral so it's obvious the mic is live.
    static func menuBarIcon(_ style: MenuBarStyle) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let color: NSColor = style == .recording ? coral : .black
            for (index, dot) in ringDotCenters(center: center, radius: 6.6).enumerated() {
                let alpha: CGFloat
                switch style {
                case .idle, .recording: alpha = 1
                case .loading: alpha = 0.35
                // A fading tail, like a spinner frozen mid-turn.
                case .working: alpha = 0.25 + 0.75 * CGFloat(index) / CGFloat(ringDotCount - 1)
                }
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: CGRect(x: dot.x - 1.45, y: dot.y - 1.45, width: 2.9, height: 2.9)).fill()
            }
            let core: CGFloat = style == .recording ? 3.4 : 2.4
            color.withAlphaComponent(style == .loading ? 0.35 : 1).setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)).fill()
            return true
        }
        image.isTemplate = style != .recording
        image.accessibilityDescription = "Audio Input"
        return image
    }

    // MARK: - App icon

    /// Coral rounded square, white ring of dots around a white microphone. `pixels` is the
    /// full canvas; the artwork sits on Apple's 824/1024 grid.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let s = CGFloat(pixels)
        let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

        // Soft drop shadow under the tile, as on other macOS icons.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = s * 12 / 1024
        shadow.shadowOffset = NSSize(width: 0, height: -s * 6 / 1024)
        shadow.set()
        coral.setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(srgbRed: 1, green: 118 / 255, blue: 131 / 255, alpha: 1), ending: coralDeep)?
            .draw(in: tilePath, angle: -90)

        let center = CGPoint(x: tile.midX, y: tile.midY)
        NSColor.white.setFill()
        let dotRadius = s * 0.036
        for dot in ringDotCenters(center: center, radius: s * 0.262) {
            NSBezierPath(ovalIn: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
        }
        drawMicrophone(center: center, scale: s, color: .white)
        return rep
    }

    /// A simple microphone: rounded capsule, U-shaped holder, stem and base.
    private static func drawMicrophone(center: CGPoint, scale s: CGFloat, color: NSColor) {
        color.setFill()
        color.setStroke()
        let bodyWidth = s * 0.105, bodyHeight = s * 0.175
        let bodyRect = CGRect(x: center.x - bodyWidth / 2, y: center.y - s * 0.035, width: bodyWidth, height: bodyHeight)
        NSBezierPath(roundedRect: bodyRect, xRadius: bodyWidth / 2, yRadius: bodyWidth / 2).fill()

        let line = s * 0.024
        let holder = NSBezierPath()
        holder.lineWidth = line
        holder.lineCapStyle = .round
        let holderRadius = s * 0.085
        let holderCenter = CGPoint(x: center.x, y: bodyRect.minY + bodyWidth / 2 + s * 0.012)
        holder.appendArc(withCenter: holderCenter, radius: holderRadius, startAngle: 180, endAngle: 0, clockwise: false)
        holder.stroke()

        let stem = NSBezierPath()
        stem.lineWidth = line
        stem.lineCapStyle = .round
        stem.move(to: CGPoint(x: center.x, y: holderCenter.y - holderRadius))
        stem.line(to: CGPoint(x: center.x, y: holderCenter.y - holderRadius - s * 0.05))
        stem.move(to: CGPoint(x: center.x - s * 0.045, y: holderCenter.y - holderRadius - s * 0.05))
        stem.line(to: CGPoint(x: center.x + s * 0.045, y: holderCenter.y - holderRadius - s * 0.05))
        stem.stroke()
    }

    /// Writes AppIcon.iconset PNGs (for `iconutil -c icns`).
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                let png = appIcon(pixels: points * scale).representation(using: .png, properties: [:])!
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
