import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var hotkeyManager: HotkeyManager?
    private var recordingState = RecordingState()

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
            button.action = #selector(togglePopover)
            button.target = self
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Whispered", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Enregistrer (⌘ droite)", action: #selector(startRecordingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Télécharger le modèle", action: #selector(downloadModel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Préférences...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
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

    @objc private func togglePopover() {
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

    @objc private func downloadModel() {
        WhisperService.shared.downloadModelIfNeeded { result in
            DispatchQueue.main.async {
                let alert = NSAlert()
                switch result {
                case .success:
                    alert.messageText = "Modèle téléchargé"
                    alert.informativeText = "Le modèle Whisper Base a été téléchargé avec succès."
                    alert.alertStyle = .informational
                case .failure(let error):
                    alert.messageText = "Erreur de téléchargement"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                }
                alert.runModal()
            }
        }
    }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

import AVFoundation
