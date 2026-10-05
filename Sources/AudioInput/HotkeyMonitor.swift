import AppKit
import Carbon.HIToolbox

/// Hold-to-talk on the Right Option key, watched system-wide.
///
/// If any other key is pressed while Right Option is held, the user is typing a shortcut
/// or a special character (⌥E, ⌥⌘…), so the dictation is cancelled instead.
/// Global key monitoring only works once the Accessibility permission is granted.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Device-specific bit for the right-hand Option key (NX_DEVICERALTKEYMASK), so the left
    /// Option key keeps working normally.
    private static let rightOptionMask: UInt = 0x40

    private var monitors: [Any] = []
    private var isHeld = false

    func start() {
        stop()
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in self?.handleFlagsChanged(event) }
        let keyHandler: (NSEvent) -> Void = { [weak self] _ in self?.handleOtherKey() }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler),
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flagsHandler($0); return $0 },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyHandler($0); return $0 },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isHeld = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_RightOption) {
            let down = event.modifierFlags.rawValue & Self.rightOptionMask != 0
            if down, !isHeld {
                isHeld = true
                onPress?()
            } else if !down, isHeld {
                isHeld = false
                onRelease?()
            }
        } else if isHeld {
            handleOtherKey()
        }
    }

    private func handleOtherKey() {
        guard isHeld else { return }
        isHeld = false
        onCancel?()
    }
}
