import AppKit
import AVFoundation
import SwiftUI
import os.log

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var floatingPanel: NSPanel?
    private var hotkeyManager: HotkeyManager?
    private let recordingState = RecordingState()

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var clickOutsideMonitor: Any?
    private var hidePanelTask: Task<Void, Never>?
    /// Arrêt différé d'une dictée lancée depuis le menu, annulé si la dictée
    /// se termine avant : sinon il coupait la dictée d'après.
    private var menuRecordingTimeout: Task<Void, Never>?

    /// Session de dictée en direct du moteur système, quand elle est activée
    private var liveSession: (any LiveDictationSession)?
    /// Format attendu par le moteur système, interrogé une fois au lancement
    private var liveAudioFormat: AVAudioFormat?

    /// En mode « appuyer », indique qu'un enregistrement est en cours
    private var isToggleRecordingActive = false
    /// Raccourci qui a lancé l'enregistrement en cours
    private var activeRole: HotkeyRole = .primary
    /// Numéro de la dictée en cours. Deux dictées qui se chevauchent — la
    /// seconde lancée pendant que la première transcrit encore — se marchaient
    /// dessus : le résultat de la première écrasait le statut de la seconde et
    /// masquait son popup.
    private var dictationGeneration = 0

    private static let logger = Logger(subsystem: "com.whispered", category: "App")

    // MARK: - Préférences lues à la volée

    private var currentPopupMode: PopupMode {
        let raw = UserDefaults.standard.string(forKey: "popupMode") ?? PopupMode.standard.rawValue
        return PopupMode(rawValue: raw) ?? .standard
    }

    private var currentHotkeyChoice: HotkeyChoice {
        HotkeySettingsManager.shared.hotkeyChoice
    }

    private var currentRecordingMode: RecordingMode {
        HotkeySettingsManager.shared.recordingMode
    }

    private var insertionMode: InsertionMode {
        let raw = UserDefaults.standard.string(forKey: "insertionMode") ?? InsertionMode.direct.rawValue
        return InsertionMode(rawValue: raw) ?? .direct
    }

    /// Affichage du texte pendant la dictée par le moteur système (macOS 26+).
    /// Il ne sert qu'à l'affichage : le texte inséré reste celui de Parakeet,
    /// plus fidèle sur le jargon et la ponctuation.
    private var isLivePreviewEnabled: Bool {
        guard #available(macOS 26.0, *), AppleSpeechEngine.isSupported else { return false }
        return UserDefaults.standard.object(forKey: "livePreviewEnabled") as? Bool ?? true
    }

    /// Traduire vers l'anglais plutôt que transcrire. Possible avec whisper
    /// seulement : Parakeet ne traduit pas.
    private var translateToEnglish: Bool {
        UserDefaults.standard.bool(forKey: "translateToEnglish")
    }

    private var selectedLanguage: String {
        get { UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLanguage") }
    }

    /// Mode d'insertion effectif, le second raccourci pouvant forcer la copie
    private var effectiveInsertionMode: InsertionMode {
        if activeRole == .secondary,
           HotkeySettingsManager.shared.secondaryAction == .clipboardOnly {
            return .clipboardOnly
        }
        return insertionMode
    }

    /// La dictée en cours doit-elle passer par le modèle de langue du système
    private var shouldReformulate: Bool {
        activeRole == .secondary
            && HotkeySettingsManager.shared.secondaryAction == .reformulate
    }

    /// Modèle à employer pour la dictée en cours, nil pour le modèle actif
    private var effectiveModel: TranscriptionModel? {
        if activeRole == .secondary,
           HotkeySettingsManager.shared.secondaryAction == .alternateEngine {
            return TranscriptionService.shared.alternateModel
        }
        return nil
    }

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupFloatingPanel()
        observeNotifications()

        AudioRecorder.shared.onLevel = { [weak self] level in
            self?.recordingState.appendLevel(level)
        }
        AudioRecorder.shared.onSilenceTimeout = { [weak self] in
            self?.handleSilenceTimeout()
        }

        // Le VAD pèse 0,8 Mo : on le récupère en tâche de fond au premier lancement
        ModelStore.shared.downloadVADModelIfNeeded()

        if hasCompletedOnboarding {
            Permissions.shared.refresh()
            if Permissions.shared.accessibility.isGranted {
                setupHotkeyManager()
            } else {
                Permissions.shared.promptAccessibility()
            }
            Task { await Permissions.shared.requestMicrophone() }
        } else {
            showOnboarding()
        }

        Permissions.shared.startMonitoring()

        // Charge le modèle d'avance pour que la première dictée soit aussi
        // rapide que les suivantes
        TranscriptionService.shared.preload()

        // Le format du moteur système doit être connu avant de démarrer la
        // capture : on l'interroge une fois, au lancement.
        refreshLiveAudioFormat()
    }

    /// Un utilisateur qui vient de la v1 a déjà accordé les permissions et
    /// choisi son raccourci : la présence de ses réglages vaut onboarding fait.
    private var hasCompletedOnboarding: Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "onboardingCompleted") { return true }
        let legacyKeys = ["hotkeyChoice", "popupMode", "selectedModel", "selectedLanguage"]
        if legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            defaults.set(true, forKey: "onboardingCompleted")
            return true
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(popupModeDidChange),
            name: .popupModeDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(hotkeySettingsDidChange),
            name: .hotkeySettingsDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(permissionsDidBecomeComplete),
            name: .permissionsDidBecomeComplete,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(audioCaptureInterrupted),
            name: .audioCaptureInterrupted,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(selectedLanguageDidChange),
            name: .selectedLanguageDidChange,
            object: nil
        )
    }

    private func cleanup() {
        NotificationCenter.default.removeObserver(self)
        hidePanelTask?.cancel()
        menuRecordingTimeout?.cancel()

        Permissions.shared.stopMonitoring()
        hotkeyManager?.stop()
        hotkeyManager = nil

        AudioRecorder.shared.cleanup()
        TranscriptionService.shared.cleanup()

        removeClickOutsideMonitor()

        floatingPanel?.close()
        floatingPanel = nil
        settingsWindow?.close()
        settingsWindow = nil
        historyWindow?.close()
        historyWindow = nil
        onboardingWindow?.close()
        onboardingWindow = nil

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Icône de la barre des menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Whispered"
        )
        statusItem?.button?.action = #selector(statusItemClicked)
        statusItem?.button?.target = self
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateStatusIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Whispered")
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func showMenu() {
        let menu = NSMenu()

        let service = TranscriptionService.shared
        let header = NSMenuItem(title: "Whispered", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let engineItem = NSMenuItem(
            title: service.isReady
                ? "Moteur : \(service.currentModel.displayName)"
                : "Aucun modèle installé",
            action: nil,
            keyEquivalent: ""
        )
        engineItem.isEnabled = false
        menu.addItem(engineItem)

        menu.addItem(.separator())

        let recordItem = NSMenuItem(
            title: "Dicter (\(currentHotkeyChoice.fullDescription))",
            action: #selector(startRecordingFromMenu),
            keyEquivalent: ""
        )
        recordItem.target = self
        recordItem.isEnabled = service.isReady
        menu.addItem(recordItem)

        if let last = TranscriptionHistory.shared.mostRecent {
            let repeatItem = NSMenuItem(
                title: "Réinsérer : \(last.preview)",
                action: #selector(repeatLastFromMenu),
                keyEquivalent: ""
            )
            repeatItem.target = self
            menu.addItem(repeatItem)
        }

        let historyItem = NSMenuItem(
            title: "Historique…",
            action: #selector(openHistory),
            keyEquivalent: "y"
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())
        addLanguageMenuItems(to: menu)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Préférences…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Langues favorites et mode automatique.
    /// Parakeet détecte la langue tout seul : le choix ne s'applique qu'à whisper.
    private func addLanguageMenuItems(to menu: NSMenu) {
        let supportsLanguage = TranscriptionService.shared.currentModel.supportsLanguageSelection
        let title = supportsLanguage ? "Langue" : "Langue détectée automatiquement"
        let langHeader = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        langHeader.isEnabled = false
        menu.addItem(langHeader)

        guard supportsLanguage else { return }

        let current = selectedLanguage
        for lang in FavoriteLanguagesManager.shared.favoriteLanguages {
            let item = NSMenuItem(
                title: lang.displayName,
                action: #selector(selectLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.code
            item.state = (current == lang.code) ? .on : .off
            menu.addItem(item)
        }

        let autoItem = NSMenuItem(
            title: Language.auto.displayName,
            action: #selector(selectLanguageFromMenu(_:)),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.representedObject = "auto"
        autoItem.state = (current == "auto") ? .on : .off
        menu.addItem(autoItem)
    }

    @objc private func selectLanguageFromMenu(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        selectedLanguage = code
        NotificationCenter.default.post(name: .selectedLanguageDidChange, object: code)
        refreshLiveAudioFormat()
    }

    /// Le format attendu par le moteur système dépend de la locale : il doit
    /// être réinterrogé quand la langue change.
    private func refreshLiveAudioFormat() {
        guard #available(macOS 26.0, *), isLivePreviewEnabled else {
            liveAudioFormat = nil
            return
        }
        let language = selectedLanguage
        Task { [weak self] in
            let format = await AppleSpeechEngine.preferredAudioFormat(for: language)
            self?.liveAudioFormat = format
        }
    }

    // MARK: - Popup flottant

    private func setupFloatingPanel() {
        let size = currentPopupMode.size

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = size
        panel.maxSize = size

        let hosting = NSHostingView(
            rootView: RecordingPopup(state: recordingState, mode: currentPopupMode)
                .frame(width: size.width, height: size.height)
                .background(VisualEffectBlur())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )

        let wrapper = NSView(frame: NSRect(origin: .zero, size: size))
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 14
        wrapper.layer?.masksToBounds = true
        hosting.frame = wrapper.bounds
        hosting.autoresizingMask = [.width, .height]
        wrapper.addSubview(hosting)

        panel.contentView = wrapper
        floatingPanel = panel
    }

    @objc private func popupModeDidChange() {
        let wasVisible = floatingPanel?.isVisible ?? false
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        setupFloatingPanel()
        if wasVisible { showPanel() }
    }

    @objc private func hotkeySettingsDidChange() {
        hotkeyManager?.updateHotkeys(
            primary: currentHotkeyChoice,
            secondary: HotkeySettingsManager.shared.secondaryHotkeyChoice
        )
        if isToggleRecordingActive {
            isToggleRecordingActive = false
            stopRecording()
        }
        popupModeDidChange()
    }

    @objc private func selectedLanguageDidChange() {
        refreshLiveAudioFormat()
    }

    @objc private func permissionsDidBecomeComplete() {
        setupHotkeyManager()
    }

    /// Le système a coupé la capture (casque branché, entrée par défaut
    /// changée). Sans ce message, la dictée partait silencieuse sans explication.
    @objc private func audioCaptureInterrupted() {
        guard recordingState.isRecording else { return }
        recordingState.isRecording = false
        isToggleRecordingActive = false
        updateStatusIcon(recording: false)
        recordingState.statusText = "Micro changé, dictée interrompue"
        Task { [weak self] in
            guard let self else { return }
            let session = self.liveSession
            self.liveSession = nil
            await session?.cancelSession()
        }
        hidePanelAfterDelay(2.5)
    }

    private func showPanel() {
        guard let panel = floatingPanel else { return }
        hidePanelTask?.cancel()

        guard !panel.isVisible else { return }
        if let screen = NSScreen.main {
            let size = currentPopupMode.size
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 60
            ))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
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
            // Ce handler est appelé sur le main thread, mais n'est pas typé
            // comme tel : AppKit ne porte pas encore l'annotation.
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    private func hidePanelAfterDelay(_ delay: TimeInterval = 1.6) {
        hidePanelTask?.cancel()
        hidePanelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.hidePanel()
            self.recordingState.statusText = "Prêt"
            self.recordingState.resetLevels()
        }
    }

    private func addClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let panel = self.floatingPanel, panel.isVisible,
                      !panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
        clickOutsideMonitor = nil
    }

    // MARK: - Raccourcis

    private func setupHotkeyManager() {
        guard hotkeyManager == nil, AXIsProcessTrusted() else { return }

        let manager = HotkeyManager { [weak self] role, isPressed in
            Task { @MainActor in
                self?.handleHotkeyEvent(role: role, isPressed: isPressed)
            }
        }
        if manager.start() {
            hotkeyManager = manager
            Self.logger.info("Raccourcis actifs")
        } else {
            Self.logger.error("Démarrage des raccourcis impossible")
        }
    }

    private func handleHotkeyEvent(role: HotkeyRole, isPressed: Bool) {
        // Le second raccourci peut déclencher une action qui n'enregistre rien
        if role == .secondary, HotkeySettingsManager.shared.secondaryAction == .repeatLast {
            if isPressed { repeatLastTranscription() }
            return
        }

        // Un enregistrement appartient au rôle qui l'a lancé : le relâchement
        // de l'autre touche ne doit pas le couper.
        if recordingState.isRecording && role != activeRole { return }
        if isPressed && !recordingState.isRecording { activeRole = role }

        switch currentRecordingMode {
        case .hold:
            if isPressed {
                startRecording()
            } else {
                stopRecording()
            }
        case .toggle:
            guard isPressed else { return }
            if isToggleRecordingActive {
                isToggleRecordingActive = false
                stopRecording()
            } else {
                isToggleRecordingActive = true
                startRecording()
            }
        }
    }

    /// En mode « appuyer », un silence prolongé arrête l'enregistrement : sinon
    /// il faut penser à rappuyer, et la dictée part avec dix secondes de blanc.
    private func handleSilenceTimeout() {
        guard recordingState.isRecording, currentRecordingMode == .toggle else { return }
        isToggleRecordingActive = false
        stopRecording()
    }

    @objc private func startRecordingFromMenu() {
        activeRole = .primary
        if currentRecordingMode == .toggle {
            guard !isToggleRecordingActive else { return }
            isToggleRecordingActive = true
            startRecording()
        } else {
            startRecording()
            // Sans touche à relâcher, on s'arrête au bout d'un temps borné
            menuRecordingTimeout?.cancel()
            menuRecordingTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.recordingState.isRecording else { return }
                self.stopRecording()
            }
        }
    }

    @objc private func repeatLastFromMenu() {
        repeatLastTranscription()
    }

    // MARK: - Dictée

    private func startRecording() {
        guard !recordingState.isRecording else { return }

        // Sans modèle téléchargé, on dicte quand même si le moteur du système
        // est disponible : c'est tout l'intérêt de ce chemin, pouvoir dicter
        // pendant que les 638 Mo arrivent.
        if !TranscriptionService.shared.isReady, !isLivePreviewEnabled {
            recordingState.statusText = "Aucun modèle installé"
            showPanel()
            hidePanelAfterDelay(2.5)
            openSettings()
            return
        }

        recordingState.resetLevels()
        recordingState.liveText = ""
        recordingState.isRecording = true
        recordingState.statusText = "À l'écoute…"
        showPanel()
        updateStatusIcon(recording: true)

        // Le direct démarre en parallèle : les premiers blocs partent avant que
        // la session système soit prête et sont simplement perdus pour
        // l'affichage, jamais pour le texte final.
        AudioRecorder.shared.liveOutputFormat = isLivePreviewEnabled ? liveAudioFormat : nil
        AudioRecorder.shared.setLiveConsumer(nil)
        if isLivePreviewEnabled, liveAudioFormat != nil {
            startLivePreview()
        }

        do {
            try AudioRecorder.shared.start()
        } catch AudioRecorderError.microphonePending {
            // L'invite système a été esquivée : la redemander plutôt que
            // d'afficher « réessayez » indéfiniment.
            recordingState.isRecording = false
            recordingState.statusText = "Autorisation du microphone demandée…"
            updateStatusIcon(recording: false)
            hidePanelAfterDelay(3)
            Task { await Permissions.shared.requestMicrophone() }
        } catch {
            recordingState.isRecording = false
            recordingState.statusText = error.localizedDescription
            updateStatusIcon(recording: false)
            hidePanelAfterDelay(3)
        }
    }

    private func stopRecording() {
        guard recordingState.isRecording else { return }

        menuRecordingTimeout?.cancel()
        menuRecordingTimeout = nil
        recordingState.isRecording = false
        recordingState.statusText = "Transcription…"
        updateStatusIcon(recording: false)

        dictationGeneration += 1
        let generation = dictationGeneration
        let samples = AudioRecorder.shared.stop()
        let session = liveSession
        liveSession = nil

        let model = effectiveModel
        let mode = effectiveInsertionMode
        let language = selectedLanguage
        let reformulate = shouldReformulate
        let translate = translateToEnglish
        let hasLocalModel = TranscriptionService.shared.isReady

        guard !samples.isEmpty else {
            recordingState.statusText = "Rien n'a été enregistré"
            Task { _ = await session?.finishSession() }
            hidePanelAfterDelay()
            return
        }

        Task { [weak self] in
            guard let self else { return }

            // Sans modèle téléchargé, le moteur système fournit le texte inséré.
            guard hasLocalModel else {
                let text = await session?.finishSession() ?? ""
                guard self.dictationGeneration == generation else { return }
                self.handleSystemText(text, mode: mode, duration: Double(samples.count) / 16000)
                return
            }

            Task { _ = await session?.finishSession() }

            do {
                let outcome = try await TranscriptionService.shared.transcribe(
                    samples: samples,
                    using: model,
                    language: language,
                    translateToEnglish: translate
                )
                if reformulate {
                    if self.dictationGeneration == generation {
                        self.recordingState.statusText = "Réécriture…"
                    }
                    let rewritten = await self.reformulated(outcome.text)
                    guard self.dictationGeneration == generation else { return }
                    self.handle(outcome: outcome, text: rewritten, mode: mode)
                } else {
                    guard self.dictationGeneration == generation else { return }
                    self.handle(outcome: outcome, mode: mode)
                }
            } catch {
                // Le texte est quand même inséré si une dictée plus récente a
                // pris le relais : seul l'affichage est réservé à la dernière.
                guard self.dictationGeneration == generation else { return }
                Self.logger.error("Transcription échouée : \(error.localizedDescription, privacy: .public)")
                self.recordingState.statusText = error.localizedDescription
                self.hidePanelAfterDelay(error is TranscriptionError ? 1.6 : 3)
            }
        }
    }

    /// Passe le texte au modèle de langue du système. En cas d'indisponibilité
    /// ou de lenteur, le texte d'origine est rendu tel quel : une dictée ne doit
    /// jamais être perdue parce que la réécriture a échoué.
    private func reformulated(_ text: String) async -> String {
        guard #available(macOS 26.0, *) else { return text }
        let style = ReformulationStyle(
            rawValue: HotkeySettingsManager.shared.reformulationStyle
        ) ?? .clean
        return await TextReformulator.reformulate(text, style: style)
    }

    private func handle(outcome: TranscriptionOutcome, text: String? = nil, mode: InsertionMode) {
        let corrected = TextCorrections.shared.apply(to: text ?? outcome.text)
        let injection = TextInjector.shared.inject(corrected, mode: mode)

        recordingState.statusText = injection.message
        recordingState.lastTranscription = corrected

        TranscriptionHistory.shared.add(
            TranscriptionEntry(
                text: corrected,
                engine: outcome.model.engine.displayName,
                language: outcome.language,
                audioDuration: outcome.audioDuration,
                processingTime: outcome.processingTime
            )
        )

        Self.logger.info("Dictée : \(outcome.audioDuration, privacy: .public) s d'audio transcrites par \(outcome.model.rawValue, privacy: .public)")

        hidePanelAfterDelay()
    }

    /// Ouvre la session de dictée en direct du système.
    private func startLivePreview() {
        guard #available(macOS 26.0, *) else { return }
        let language = selectedLanguage
        Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await AppleSpeechEngine.shared.startLiveSession(
                    languageCode: language
                ) { [weak self] partial in
                    guard let self, self.recordingState.isRecording else { return }
                    self.recordingState.liveText = partial
                }
                // La dictée peut avoir été relâchée entre-temps
                guard self.recordingState.isRecording else {
                    await session.cancelSession()
                    return
                }
                // La session recalcule son format pour sa locale : si la langue
                // a changé depuis le lancement, l'enregistreur convertirait vers
                // l'ancien format et la session ne comprendrait rien.
                guard session.audioFormat == AudioRecorder.shared.liveOutputFormat else {
                    Self.logger.notice("Format du direct périmé, session abandonnée")
                    self.liveAudioFormat = session.audioFormat
                    await session.cancelSession()
                    return
                }
                self.liveSession = session
                AudioRecorder.shared.setLiveConsumer { [weak session] buffer in
                    session?.appendBuffer(buffer)
                }
            } catch {
                Self.logger.notice("Direct indisponible : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Texte venu du moteur système, utilisé quand aucun modèle local n'est installé.
    private func handleSystemText(_ text: String, mode: InsertionMode, duration: TimeInterval) {
        let cleaned = TranscriptionSanitizer.clean(text)
        guard !cleaned.isEmpty else {
            recordingState.statusText = "Aucune parole détectée"
            hidePanelAfterDelay()
            return
        }
        let corrected = TextCorrections.shared.apply(to: cleaned)
        let injection = TextInjector.shared.inject(corrected, mode: mode)
        recordingState.statusText = injection.message
        recordingState.lastTranscription = corrected
        TranscriptionHistory.shared.add(
            TranscriptionEntry(
                text: corrected,
                engine: "Système",
                language: nil,
                audioDuration: duration,
                processingTime: 0
            )
        )
        hidePanelAfterDelay()
    }

    private func repeatLastTranscription() {
        let text = TranscriptionHistory.shared.mostRecent?.text ?? recordingState.lastTranscription
        guard !text.isEmpty else {
            recordingState.statusText = "Aucune dictée à réinsérer"
            showPanel()
            hidePanelAfterDelay()
            return
        }
        let injection = TextInjector.shared.inject(text, mode: insertionMode)
        recordingState.statusText = injection.message
        recordingState.lastTranscription = text
        showPanel()
        hidePanelAfterDelay()
    }

    // MARK: - Fenêtres

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Préférences"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView()))
            window.title = "Historique"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOnboarding() {
        let view = OnboardingView { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.setupHotkeyManager()
            if !TranscriptionService.shared.isReady {
                self?.openSettings()
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Bienvenue"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Fond translucide du popup

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

// MARK: - Notifications

extension Notification.Name {
    static let popupModeDidChange = Notification.Name("popupModeDidChange")
}
