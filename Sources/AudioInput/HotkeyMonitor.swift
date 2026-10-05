import AppKit
import Carbon.HIToolbox

/// The key held to dictate. Only modifier keys, so holding one never types anything.
enum Hotkey: String, CaseIterable {
    case rightOption, rightCommand, rightControl, function

    static let `default` = Hotkey.rightOption

    /// For the menu.
    var title: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control (external keyboards)"
        case .function: return "fn / 🌐 Globe"
        }
    }

    /// For status text: "hold Right ⌥ and speak".
    var shortName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .function: return "fn"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return UInt16(kVK_RightOption)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightControl: return UInt16(kVK_RightControl)
        case .function: return UInt16(kVK_Function)
        }
    }

    /// Right-hand keys are read from their device-specific bits (NX_DEVICER…KEYMASK), so the
    /// left-hand key of the same kind keeps working normally.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: return flags.rawValue & 0x40 != 0
        case .rightCommand: return flags.rawValue & 0x10 != 0
        case .rightControl: return flags.rawValue & 0x2000 != 0
        case .function: return flags.contains(.function)
        }
    }
}

/// Hold-to-talk on the chosen modifier key, watched system-wide.
///
/// If any other key is pressed while it's held, the user is typing a shortcut or a special
/// character (⌥E, ⌘C…), so the dictation is cancelled instead.
/// Global key monitoring only works once the Accessibility permission is granted.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    var key = Hotkey.default {
        didSet { if isHeld { handleOtherKey() } }
    }

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
        if event.keyCode == key.keyCode {
            let down = key.isDown(event.modifierFlags)
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
