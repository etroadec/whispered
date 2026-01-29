import AppKit
import SwiftUI
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var floatingPanel: NSPanel?
    private var hotkeyManager: HotkeyManager?
    private var recordingState = RecordingState()
    private var settingsWindow: NSWindow?
    private var clickOutsideMonitor: Any?

    // MARK: - Whisper Blank Audio Patterns

    /// Patterns Whisper indiquant un audio vide ou non-parole
    private static let whisperBlankPatterns: [String] = [
        "[BLANK_AUDIO]",
        "[blank_audio]",
        "[Blank Audio]",
        "(blank audio)",
        "[MUSIC]",
        "[Music]",
        "[APPLAUSE]",
        "[Applause]",
        "[LAUGHTER]",
        "[Laughter]",
        "[SILENCE]",
        "[Silence]",
        "[INAUDIBLE]",
        "[inaudible]",
        "[NO SPEECH]",
        "[no speech]",
    ]

    /// Regex précompilée pour détecter les textes composés uniquement de marqueurs [xxx] ou (xxx)
    private static let bracketOnlyRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(\[[^\]]+\]|\([^\)]+\))(\s*(\[[^\]]+\]|\([^\)]+\)))*$"#, options: .caseInsensitive)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupFloatingPanel()

        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        if AXIsProcessTrusted() {
            print("AppDelegate: Accessibility already granted, setting up hotkey manager")
            setupHotkeyManager()
        } else {
            print("AppDelegate: Accessibility NOT granted, will setup after permission")
        }

        requestPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    private func cleanup() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil

        hotkeyManager?.stop()
        hotkeyManager = nil

        AudioRecorder.shared.cleanup()
        WhisperService.shared.cleanup()

        removeClickOutsideMonitor()

        floatingPanel?.close()
        floatingPanel = nil

        settingsWindow?.close()
        settingsWindow = nil

        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whispered")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Whispered", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let modelItem = NSMenuItem(title: "Modèle: \(WhisperService.shared.getCurrentModel().rawValue.capitalized)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        let recordItem = NSMenuItem(title: "Enregistrer (⌘ droite)", action: #selector(startRecordingFromMenu), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Préférences...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Floating Panel (remplace NSPopover)

    private func setupFloatingPanel() {
        let contentSize = NSSize(width: 280, height: 180)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let hostingView = NSHostingView(rootView:
            RecordingPopup(state: recordingState)
                .background(VisualEffectBlur())
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )

        let wrapperView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        wrapperView.wantsLayer = true
        wrapperView.layer?.cornerRadius = 12
        wrapperView.layer?.masksToBounds = true

        hostingView.frame = wrapperView.bounds
        hostingView.autoresizingMask = [.width, .height]
        wrapperView.addSubview(hostingView)

        panel.contentView = wrapperView

        floatingPanel = panel
    }

    private func togglePanel() {
        if floatingPanel?.isVisible == true {
            hidePanel()
        } else {
            showPanelUnderStatusItem()
        }
    }

    private func showPanelUnderStatusItem() {
        guard let panel = floatingPanel,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)

        let panelSize = panel.frame.size
        let panelX = buttonFrameOnScreen.midX - (panelSize.width / 2)
        let panelY = buttonFrameOnScreen.minY - panelSize.height - 4

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let screenFrame = screen.visibleFrame
            let adjustedX = max(screenFrame.minX + 8, min(panelX, screenFrame.maxX - panelSize.width - 8))
            panel.setFrameOrigin(NSPoint(x: adjustedX, y: panelY))
        } else {
            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        addClickOutsideMonitor()
    }

    private func hidePanel() {
        guard let panel = floatingPanel, panel.isVisible else { return }

        removeClickOutsideMonitor()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    // MARK: - Click Outside Monitor

    private func addClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self = self,
                  let panel = self.floatingPanel,
                  panel.isVisible else { return }

            if !panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async {
                    self.hidePanel()
                }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func setupHotkeyManager() {
        guard hotkeyManager == nil else {
            print("AppDelegate: HotkeyManager already exists")
            return
        }

        hotkeyManager = HotkeyManager { [weak self] isPressed in
            if isPressed {
                self?.startRecording()
            } else {
                self?.stopRecording()
            }
        }

        let success = hotkeyManager?.start() ?? false
        if success {
            print("AppDelegate: Hotkey manager started successfully")
            print("AppDelegate: Event tap active = \(hotkeyManager?.isActive() ?? false)")
        } else {
            print("AppDelegate: Hotkey manager failed to start")
            hotkeyManager = nil
        }
    }

    private var accessibilityCheckTimer: Timer?

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            startAccessibilityCheck()
        }
    }

    private func startAccessibilityCheck() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityCheckTimer = nil
                print("AppDelegate: Accessibility permission granted!")
                self?.setupHotkeyManager()
            }
        }
    }

    @objc private func startRecordingFromMenu() {
        startRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.stopRecording()
        }
    }

    private func startRecording() {
        guard !recordingState.isRecording else { return }

        recordingState.isRecording = true
        recordingState.statusText = "Enregistrement..."

        showPanelUnderStatusItem()

        statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recording")

        AudioRecorder.shared.startRecording()
    }

    private func stopRecording() {
        guard recordingState.isRecording else { return }

        recordingState.isRecording = false
        recordingState.statusText = "Transcription..."

        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whispered")

        AudioRecorder.shared.stopRecording { [weak self] audioURL in
            guard let audioURL = audioURL else {
                DispatchQueue.main.async {
                    self?.recordingState.statusText = "Erreur d'enregistrement"
                    self?.hidePanelAfterDelay()
                }
                return
            }

            WhisperService.shared.transcribe(audioURL: audioURL) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        if self?.isValidTranscription(text) == true {
                            self?.recordingState.statusText = "Transcrit!"
                            self?.recordingState.lastTranscription = text
                            TextInjector.shared.injectText(text)
                        } else {
                            self?.recordingState.statusText = "Aucune parole détectée"
                            print("Whispered: Transcription ignorée (vide ou marqueur): '\(text)'")
                        }

                    case .failure(let error):
                        self?.recordingState.statusText = "Erreur: \(error.localizedDescription)"
                    }

                    self?.hidePanelAfterDelay()
                }
            }
        }
    }

    // MARK: - Transcription Validation

    private func isValidTranscription(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return false
        }

        let upperText = trimmed.uppercased()
        for pattern in Self.whisperBlankPatterns {
            if upperText == pattern.uppercased() {
                return false
            }
        }

        if let regex = Self.bracketOnlyRegex {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return false
            }
        }

        let musicSymbols = CharacterSet(charactersIn: "♪♫🎵🎶")
        let withoutMusic = trimmed.unicodeScalars.filter { !musicSymbols.contains($0) }
        if withoutMusic.isEmpty || String(String.UnicodeScalarView(withoutMusic)).trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }

        if trimmed.count < 3 {
            return false
        }

        return true
    }

    private func hidePanelAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hidePanel()
            self?.recordingState.statusText = "Prêt"
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)

            settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow?.title = "Whispered - Préférences"
            settingsWindow?.styleMask = [.titled, .closable]
            settingsWindow?.setContentSize(NSSize(width: 500, height: 620))
            settingsWindow?.center()
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
