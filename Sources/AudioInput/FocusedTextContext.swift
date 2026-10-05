import ApplicationServices
import DictationCore

/// The text just before the cursor in the field being dictated into, read through the
/// Accessibility API (the permission the app already has for ⌘V). It tells the AI review what the
/// topic is, so it can choose between similar-sounding words ("app" vs "act").
///
/// Best effort: apps that don't expose their text (some browsers and Electron apps) return nil.
/// Password fields are never read. The text stays in memory and is never logged.
enum FocusedTextContext {
    /// Kept short: a frozen app must not hold up dictation.
    private static let timeout: Float = 0.2

    static func read() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: systemWide),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let field = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(field, timeout)

        let secure = kAXSecureTextFieldSubrole as String
        if attribute(kAXSubroleAttribute, of: field) as? String == secure
            || attribute(kAXRoleAttribute, of: field) as? String == secure {
            return nil
        }
        guard let value = attribute(kAXValueAttribute, of: field) as? String, !value.isEmpty else { return nil }

        // Everything before the cursor (or before the selection, which the paste will replace).
        let utf16 = Array(value.utf16)
        var end = utf16.count
        if let rangeValue = attribute(kAXSelectedTextRangeAttribute, of: field),
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                end = min(max(range.location, 0), end)
            }
        }
        let start = max(0, end - AIReviewer.maxContextCharacters)
        var before = String(decoding: utf16[start..<end], as: UTF16.self)
        // Don't start mid-word when the text was cut.
        if start > 0, let space = before.firstIndex(where: \.isWhitespace) {
            before = String(before[space...])
        }
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
