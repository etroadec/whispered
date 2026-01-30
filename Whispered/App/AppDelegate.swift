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
    
    // MARK: - Toggle Mode State
    
    /// In toggle mode, tracks if recording is active (toggled on)
    private var isToggleRecordingActive = false
    
    // MARK: - Popup Mode
    
    private var currentPopupMode: PopupMode {
        let raw = UserDefaults.standard.string(forKey: "popupMode") ?? PopupMode.standard.rawValue
        return PopupMode(rawValue: raw) ?? .standard
    }
    
    // MARK: - Hotkey Settings
    
    private var currentHotkeyChoice: HotkeyChoice {
        HotkeySettingsManager.shared.hotkeyChoice
    }
    
    private var currentRecordingMode: RecordingMode {
        HotkeySettingsManager.shared.recordingMode
    }
    
    // MARK: - Language Settings
    
    private var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLanguage") }
    }
    
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
    
    /// Regex precompilee pour detecter les textes composes uniquement de marqueurs [xxx] ou (xxx)
    private static let bracketOnlyRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(\[[^\]]+\]|\([^\)]+\))(\s*(\[[^\]]+\]|\([^\)]+\)))*$"#, options: .caseInsensitive)
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupFloatingPanel()
        
        // Observer pour changement de mode popup
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popupModeDidChange),
            name: .popupModeDidChange,
            object: nil
        )
        
        // Observer pour changement de settings hotkey
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsDidChange),
            name: .hotkeySettingsDidChange,
            object: nil
        )
        
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
    
    @objc private func popupModeDidChange() {
        rebuildFloatingPanel()
    }
    
    @objc private func hotkeySettingsDidChange() {
        // Update hotkey manager with new key
        hotkeyManager?.updateHotkey(currentHotkeyChoice)
        
        // Reset toggle state when settings change
        if isToggleRecordingActive {
            isToggleRecordingActive = false
            stopRecording()
        }
        
        // Rebuild panel to show updated hotkey hint
        rebuildFloatingPanel()
        
        // Update menu item text
        print("AppDelegate: Hotkey settings changed to \(currentHotkeyChoice.displayName), mode: \(currentRecordingMode.displayName)")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        // Retirer tous les observers pour éviter les crashs
        NotificationCenter.default.removeObserver(self)

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
        // Clic gauche ou droit ouvre toujours le menu
        showMenu()
    }
    
    // MARK: - Context Menu
    
    private func showMenu() {
        let menu = NSMenu()
        
        // Header
        let titleItem = NSMenuItem(title: "Whispered", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let modelItem = NSMenuItem(title: "Modele: \(WhisperService.shared.getCurrentModel().rawValue.capitalized)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Record action
        let hotkeyDesc = currentHotkeyChoice.fullDescription
        let recordItem = NSMenuItem(title: "Enregistrer (\(hotkeyDesc))", action: #selector(startRecordingFromMenu), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Language section
        addLanguageMenuItems(to: menu)
        
        menu.addItem(NSMenuItem.separator())
        
        // Settings
        let settingsItem = NSMenuItem(title: "Preferences...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }
    
    /// Ajoute les items de langue au menu (favoris + automatique)
    private func addLanguageMenuItems(to menu: NSMenu) {
        let currentLang = selectedLanguage
        let favorites = FavoriteLanguagesManager.shared.favoriteLanguages
        
        // Titre de la section
        let langHeader = NSMenuItem(title: "Langue", action: nil, keyEquivalent: "")
        langHeader.isEnabled = false
        menu.addItem(langHeader)
        
        // Langues favorites
        for lang in favorites {
            let item = NSMenuItem(
                title: lang.displayName,
                action: #selector(selectLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            item.state = (currentLang == lang.code) ? .on : .off
            menu.addItem(item)
        }
        
        // Automatique
        let autoItem = NSMenuItem(
            title: Language.auto.displayName,
            action: #selector(selectLanguageFromMenu(_:)),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.representedObject = "auto"
        autoItem.state = (currentLang == "auto") ? .on : .off
        menu.addItem(autoItem)
        
        // Si pas de favoris, afficher un hint
        if favorites.isEmpty {
            let hintItem = NSMenuItem(title: "Definir des favoris dans Preferences", action: nil, keyEquivalent: "")
            hintItem.isEnabled = false
            menu.addItem(hintItem)
        }
    }
    
    @objc private func selectLanguageFromMenu(_ sender: NSMenuItem) {
        guard let langCode = sender.representedObject as? String else { return }
        selectedLanguage = langCode
        
        // Notification pour synchroniser l'UI des Settings si ouverte
        NotificationCenter.default.post(name: .selectedLanguageDidChange, object: langCode)
        
        print("AppDelegate: Language changed to \(langCode)")
    }
    
    // MARK: - Floating Panel (remplace NSPopover)
    
    private func setupFloatingPanel() {
        let mode = currentPopupMode
        let panelSize = mode.size
        
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        
        // Fixer la taille pour eviter le redimensionnement
        panel.minSize = panelSize
        panel.maxSize = panelSize
        
        let hostingView = NSHostingView(rootView:
            RecordingPopup(state: recordingState, mode: mode)
                .frame(width: panelSize.width, height: panelSize.height)
                .background(VisualEffectBlur())
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        
        let wrapperView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        wrapperView.wantsLayer = true
        wrapperView.layer?.cornerRadius = 12
        wrapperView.layer?.masksToBounds = true
        
        hostingView.frame = wrapperView.bounds
        wrapperView.addSubview(hostingView)
        
        panel.contentView = wrapperView
        
        floatingPanel = panel
    }
    
    private func rebuildFloatingPanel() {
        let wasVisible = floatingPanel?.isVisible ?? false
        
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        
        setupFloatingPanel()
        
        if wasVisible {
            showPanelCenteredTop()
        }
    }
    
    private func togglePanel() {
        if floatingPanel?.isVisible == true {
            hidePanel()
        } else {
            showPanelCenteredTop()
        }
    }
    
    private func showPanelCenteredTop() {
        guard let panel = floatingPanel else { return }
        
        // Si deja visible, ne pas repositionner
        guard !panel.isVisible else { return }
        
        let panelSize = currentPopupMode.size
        
        // Centrer horizontalement sur l'ecran principal, en haut avec marge
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelX = screenFrame.midX - (panelSize.width / 2)
            // Positionner en haut avec une marge de 60pt sous la barre de menu
            let panelY = screenFrame.maxY - panelSize.height - 60
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
            self?.handleHotkeyEvent(isPressed: isPressed)
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
    
    // MARK: - Hotkey Event Handling
    
    private func handleHotkeyEvent(isPressed: Bool) {
        switch currentRecordingMode {
        case .hold:
            // Mode maintenir: commence a l'appui, arrete au relachement
            if isPressed {
                startRecording()
            } else {
                stopRecording()
            }
            
        case .toggle:
            // Mode toggle: ne reagit qu'a l'appui (pas au relachement)
            if isPressed {
                if isToggleRecordingActive {
                    // Deuxieme appui: arreter l'enregistrement
                    isToggleRecordingActive = false
                    stopRecording()
                } else {
                    // Premier appui: demarrer l'enregistrement
                    isToggleRecordingActive = true
                    startRecording()
                }
            }
            // On ignore le relachement en mode toggle
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
        // En mode toggle, on simule un appui
        if currentRecordingMode == .toggle {
            if !isToggleRecordingActive {
                isToggleRecordingActive = true
                startRecording()
                // L'utilisateur devra cliquer à nouveau pour arrêter
            }
            // Si déjà actif, on ne fait rien (l'utilisateur peut utiliser la touche)
        } else {
            // Mode hold: enregistrement de 5 secondes max depuis le menu
            startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.stopRecording()
            }
        }
    }
    
    private func startRecording() {
        guard !recordingState.isRecording else { return }
        
        recordingState.isRecording = true
        recordingState.statusText = "Enregistrement..."
        
        showPanelCenteredTop()
        
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
                            self?.recordingState.statusText = "Aucune parole detectee"
                            print("Whispered: Transcription ignoree (vide ou marqueur): '\(text)'")
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
        
        let musicSymbols = CharacterSet(charactersIn: "")
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
            self?.recordingState.statusText = "Pret"
        }
    }
    
    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            
            settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow?.title = "Whispered - Preferences"
            settingsWindow?.styleMask = [.titled, .closable]
            settingsWindow?.setContentSize(NSSize(width: 500, height: 850))
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

// MARK: - Notification Names

extension Notification.Name {
    static let popupModeDidChange = Notification.Name("popupModeDidChange")
}
