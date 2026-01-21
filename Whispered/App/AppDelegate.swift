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
        setupHotkeyManager()
        requestPermissions()

        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)
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
        let event = NSApp.currentEvent!

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
        popover?.contentSize = NSSize(width: 300, height: 150)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: RecordingPopup(state: recordingState))
    }

    private func setupHotkeyManager() {
        hotkeyManager = HotkeyManager { [weak self] isPressed in
            DispatchQueue.main.async {
                if isPressed {
                    self?.startRecording()
                } else {
                    self?.stopRecording()
                }
            }
        }
        hotkeyManager?.start()
    }

    private func requestPermissions() {
        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.showPermissionAlert(for: "Microphone")
                }
            }
        }

        // Check accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !trusted {
            print("Accessibility permission required for global hotkey")
        }
    }

    private func showPermissionAlert(for permission: String) {
        let alert = NSAlert()
        alert.messageText = "Permission requise"
        alert.informativeText = "Whispered a besoin de l'accès au \(permission) pour fonctionner."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ouvrir les Préférences")
        alert.addButton(withTitle: "Annuler")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
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
