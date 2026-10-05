import AppKit
import Carbon.HIToolbox

/// Types text into whichever app has focus: put it on the clipboard, press ⌘V for the user,
/// then put their original clipboard back. Needs the Accessibility permission to post ⌘V.
@MainActor
final class TextInserter {
    /// Long enough for the target app to read the clipboard before it's restored.
    private static let restoreDelay: TimeInterval = 0.5

    // nspasteboard.org conventions: clipboard managers skip items marked like this,
    // so dictated text doesn't pile up in clipboard history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
            // If something else copied in the meantime, leave the clipboard alone.
            guard pasteboard.changeCount == ourChangeCount else { return }
            Self.restore(saved, to: pasteboard)
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        // Set flags explicitly so a still-held Option key can't turn this into ⌥⌘V.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { contents[type] = data }
            }
            return contents
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
