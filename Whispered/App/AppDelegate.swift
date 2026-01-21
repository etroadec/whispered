import AppKit
import SwiftUI
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hotkeyManager: HotkeyManager?
    private var recordingState = RecordingState()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()

        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Check permissions FIRST, then setup hotkey manager only if we have permission
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
        // Stop accessibility check timer
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil

        // Stop hotkey manager first
        hotkeyManager?.stop()
        hotkeyManager = nil

        // Stop any ongoing recording
        AudioRecorder.shared.cleanup()

        // Release whisper context
        WhisperService.shared.cleanup()

        // Close popover
        popover?.close()
        popover = nil

        // Close settings window
        settingsWindow?.close()
        settingsWindow = nil

        // Remove status item
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
            // Right click - show menu
            showMenu()
        } else {
            // Left click - toggle popover
            togglePopover()
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

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 280, height: 180)
        popover?.behavior = .semitransient
        popover?.animates = true
        popover?.contentViewController = NSHostingController(rootView: RecordingPopup(state: recordingState))
    }

    private func setupHotkeyManager() {
        // Don't create if already exists
        guard hotkeyManager == nil else {
            print("AppDelegate: HotkeyManager already exists")
            return
        }

        hotkeyManager = HotkeyManager { [weak self] isPressed in
            // Callback is already on main thread (via main run loop)
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
            hotkeyManager = nil  // Clean up failed manager
        }
    }

    private var accessibilityCheckTimer: Timer?

    private func requestPermissions() {
        // Request microphone permission (system handles the dialog)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // For accessibility, just trigger the system prompt if not trusted
        if !AXIsProcessTrusted() {
            // Trigger system prompt
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

            // Start polling for permission grant
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

    private func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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

        // Show popover
        if let button = statusItem?.button, popover?.isShown != true {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }

        // Update status item icon
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Recording")

        // Start audio recording
        AudioRecorder.shared.startRecording()
    }

    private func stopRecording() {
        guard recordingState.isRecording else { return }

        recordingState.isRecording = false
        recordingState.statusText = "Transcription..."

        // Update status item icon
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whispered")

        // Stop audio recording and transcribe
        AudioRecorder.shared.stopRecording { [weak self] audioURL in
            guard let audioURL = audioURL else {
                DispatchQueue.main.async {
                    self?.recordingState.statusText = "Erreur d'enregistrement"
                    self?.hidePopoverAfterDelay()
                }
                return
            }

            // Transcribe audio
            WhisperService.shared.transcribe(audioURL: audioURL) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        self?.recordingState.statusText = "Transcrit!"
                        self?.recordingState.lastTranscription = text

                        // Inject text into active field
                        TextInjector.shared.injectText(text)

                    case .failure(let error):
                        self?.recordingState.statusText = "Erreur: \(error.localizedDescription)"
                    }

                    self?.hidePopoverAfterDelay()
                }
            }
        }
    }

    private func hidePopoverAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.popover?.performClose(nil)
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
            settingsWindow?.setContentSize(NSSize(width: 500, height: 480))
            settingsWindow?.center()
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
