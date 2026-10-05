import AppKit
import AVFoundation
import DictationCore
import ServiceManagement

/// Menu-bar icon and menu, plus the two permissions the app needs: Microphone (to hear you) and
/// Accessibility (to see the dictation key globally, read the text before the cursor, and press ⌘V).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DictationController()
    private let hotkey = HotkeyMonitor()
    private var overlay: SpeakingOverlay!
    private var statusItem: NSStatusItem!
    private var accessibilityTimer: Timer?
    private var hasAccessibility = false
    private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private static let hotkeyKey = "hotkey"

    private var hotkeyChoice: Hotkey {
        get { UserDefaults.standard.string(forKey: Self.hotkeyKey).flatMap(Hotkey.init) ?? .default }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.hotkeyKey)
            hotkey.key = newValue
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let controller = controller
        overlay = SpeakingOverlay { controller.inputLevel }
        controller.onChange = { [weak self] in
            guard let self else { return }
            self.refreshIcon()
            self.overlay.update(for: controller.state)
        }
        controller.onNotice = { [weak self] text in self?.overlay.showNotice(text) }
        hotkey.onPress = { [weak self] in self?.controller.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.controller.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.controller.cancelRecording() }
        hotkey.key = hotkeyChoice

        requestMicrophone()
        checkAccessibility(prompt: true)
        controller.loadModel()
        refreshIcon()
    }

    // MARK: - Permissions

    private func requestMicrophone() {
        guard microphoneStatus == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor [weak self] in
                self?.microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                self?.refreshIcon()
            }
        }
    }

    /// Asks once, then checks every second until granted (macOS gives no callback).
    private func checkAccessibility(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        guard !hasAccessibility else {
            hotkey.start()
            return
        }
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated { [weak self] in
                guard let self, AXIsProcessTrusted() else { return }
                timer.invalidate()
                self.hasAccessibility = true
                self.hotkey.start()
                self.refreshIcon()
            }
        }
    }

    // MARK: - Menu bar

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        switch controller.state {
        case .loadingModel: button.image = Brand.menuBarIcon(.loading)
        case .recording: button.image = Brand.menuBarIcon(.recording)
        case .transcribing, .reviewing: button.image = Brand.menuBarIcon(.working)
        case .failed: button.image = symbol("exclamationmark.triangle")
        case .ready: button.image = permissionsMissing ? symbol("mic.slash") : Brand.menuBarIcon(.idle)
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Audio Input")
        image?.isTemplate = true
        return image
    }

    private var permissionsMissing: Bool { !hasAccessibility || microphoneStatus != .authorized }

    private var statusText: String {
        switch controller.state {
        case .loadingModel: return "Loading speech model…"
        case .recording: return "Listening… release \(hotkeyChoice.shortName) to type"
        case .transcribing: return "Transcribing…"
        case .reviewing: return "Reviewing with on-device AI…"
        case .failed(let message): return message
        case .ready:
            if microphoneStatus != .authorized { return "Needs microphone access" }
            if !hasAccessibility { return "Needs Accessibility permission" }
            return "Ready — hold \(hotkeyChoice.shortName) and speak"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: statusText, action: nil, keyEquivalent: "").isEnabled = false

        if microphoneStatus != .authorized {
            menu.addItem(item("Allow Microphone Access…", #selector(openMicrophoneSettings)))
        }
        if !hasAccessibility {
            menu.addItem(item("Grant Accessibility Permission…", #selector(openAccessibilitySettings)))
        }
        if let error = controller.lastError {
            menu.addItem(withTitle: "⚠︎ \(error)", action: nil, keyEquivalent: "").isEnabled = false
        }

        menu.addItem(.separator())
        if let last = controller.lastTranscript {
            let preview = last.count > 48 ? String(last.prefix(48)) + "…" : last
            let copy = item("Copy Last: “\(preview)”", #selector(copyLastTranscript))
            copy.toolTip = last
            menu.addItem(copy)
        }
        let review = item("Review with On-Device AI", #selector(toggleAIReview))
        if let reason = controller.aiReviewUnavailableReason {
            review.isEnabled = false
            review.toolTip = reason
            menu.addItem(review)
            menu.addItem(withTitle: "    \(reason)", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            review.state = controller.aiReview ? .on : .off
            menu.addItem(review)
        }
        menu.addItem(hotkeyMenuItem())
        menu.addItem(item("Edit Word List…", #selector(editWordList)))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Audio Input", #selector(quit), key: "q"))
    }

    private func hotkeyMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for key in Hotkey.allCases {
            let choice = item(key.title, #selector(chooseHotkey(_:)))
            choice.representedObject = key.rawValue
            choice.state = key == hotkeyChoice ? .on : .off
            if key == .function {
                choice.toolTip = "Set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”, "
                    + "or fn will also open emoji or start Apple's dictation."
            }
            submenu.addItem(choice)
        }
        let parent = NSMenuItem(title: "Dictation Key: \(hotkeyChoice.shortName)", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAccessibilitySettings() {
        checkAccessibility(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleAIReview() {
        controller.aiReview.toggle()
    }

    /// Opens the word list in the default text editor; edits apply to the next dictation.
    @objc private func editWordList() {
        try? Vocabulary.createDefaultFileIfMissing()
        NSWorkspace.shared.open(Vocabulary.defaultURL)
    }

    @objc private func copyLastTranscript() {
        guard let last = controller.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last, forType: .string)
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Hotkey(rawValue: raw) else { return }
        hotkeyChoice = key
        if key == .function {
            overlay.showNotice("Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings")
        }
    }

    /// Registers this copy of the app as a login item. macOS may ask to approve it in
    /// System Settings → General → Login Items; that page is opened when it does.
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            overlay.showNotice("Couldn't change Launch at Login")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
