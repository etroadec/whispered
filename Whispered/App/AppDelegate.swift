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
    private lazy var statusMenu = StatusMenuController(actions: makeStatusMenuActions())

    private var settingsWindow: NSWindow?
    private let settingsSelection = SettingsSelection()
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var clickOutsideMonitor: Any?
    private var hidePanelTask: Task<Void, Never>?
    /// Arrêt différé d'une dictée lancée depuis le menu, annulé si la dictée
    /// se termine avant : sinon il coupait la dictée d'après.
    private var menuRecordingTimeout: Task<Void, Never>?
    /// Rafraîchit le pourcentage de téléchargement tant que le menu est ouvert
    private var downloadRefreshTimer: Timer?

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
        downloadRefreshTimer?.invalidate()

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

        // Menu attaché en permanence et rempli par `menuNeedsUpdate` : c'est
        // AppKit qui l'ouvre, donc au mouse-down comme les autres extras de la
        // barre des menus, avec le clic droit et la navigation clavier. La
        // version précédente posait le menu, simulait un clic sur le bouton
        // puis le détachait aussitôt, ce qui perdait les trois.
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func updateStatusIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Whispered")
    }

    /// Tout ce que le menu affiche, relevé au moment de l'ouverture.
    private func currentMenuState() -> StatusMenuController.State {
        let service = TranscriptionService.shared
        let store = ModelStore.shared
        let permissions = Permissions.shared
        permissions.refresh()

        // Trié : l'ordre d'un dictionnaire n'est pas spécifié, et le modèle
        // nommé changeait d'une ouverture à l'autre avec deux téléchargements.
        let download = store.progress
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .first
            .map { StatusMenuController.Download(model: $0.value.model, fraction: $0.value.fraction) }

        return StatusMenuController.State(
            selectedModel: service.currentModel,
            isModelInstalled: service.isReady,
            installedModels: TranscriptionModel.allCases.filter { ModelStore.isInstalled($0) },
            // Sans modèle local, le moteur du système prend le relais : c'est
            // la même condition que dans `startRecording`.
            canDictateWithoutModel: isLivePreviewEnabled,
            isRecording: recordingState.isRecording,
            isTranscribing: service.isTranscribing,
            download: download,
            missingAccessibility: !permissions.accessibility.isGranted,
            missingMicrophone: !permissions.microphone.isGranted,
            lastDictation: TranscriptionHistory.shared.mostRecent?.text
                ?? (recordingState.lastTranscription.isEmpty ? nil : recordingState.lastTranscription),
            language: selectedLanguage,
            favoriteLanguages: FavoriteLanguagesManager.shared.favoriteLanguages,
            insertionMode: insertionMode,
            hotkeyDescription: currentHotkeyChoice.fullDescription
        )
    }

    private func makeStatusMenuActions() -> StatusMenuController.Actions {
        var actions = StatusMenuController.Actions()
        actions.dictate = { [weak self] in self?.startRecordingFromMenu() }
        actions.stopDictation = { [weak self] in
            guard let self else { return }
            self.isToggleRecordingActive = false
            self.stopRecording()
        }
        actions.repeatLast = { [weak self] in self?.repeatLastTranscription() }
        actions.openHistory = { [weak self] in self?.openHistory() }
        actions.openSettings = { [weak self] tab in self?.openSettings(tab: tab) }
        actions.selectModel = { model in
            TranscriptionService.shared.select(model: model)
        }
        actions.selectLanguage = { [weak self] code in
            self?.selectLanguage(code)
        }
        actions.selectInsertionMode = { mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "insertionMode")
        }
        actions.openAccessibilitySettings = {
            Permissions.shared.openAccessibilitySettings()
        }
        actions.openMicrophoneSettings = {
            Permissions.shared.openMicrophoneSettings()
        }
        actions.quit = { [weak self] in self?.quit() }
        return actions
    }

    /// La notification suffit : l'AppDelegate l'observe lui-même et c'est la
    /// voie commune avec les préférences. Appeler en plus le rafraîchissement
    /// ici le déclenchait trois fois par clic.
    private func selectLanguage(_ code: String) {
        selectedLanguage = code
        NotificationCenter.default.post(name: .selectedLanguageDidChange, object: code)
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
            // La langue a pu changer entre-temps : sans cette garde, une
            // réponse tardive écrasait le format de la langue courante et la
            // session en direct était abandonnée en silence.
            guard let self, self.selectedLanguage == language else { return }
            self.liveAudioFormat = format
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

    private func startRecordingFromMenu() {
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

    private func openSettings() {
        openSettings(tab: .general)
    }

    /// Ouvre les préférences sur un onglet précis. La fenêtre n'est créée
    /// qu'une fois et l'onglet est piloté par un état observable partagé : la
    /// recréer détruisait l'état SwiftUI, et une mise à jour en cours perdait
    /// sa barre de progression tout en continuant à s'installer.
    private func openSettings(tab: SettingsView.Tab) {
        settingsSelection.tab = tab

        if settingsWindow == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: SettingsView(selection: settingsSelection)
                )
            )
            window.title = "Préférences"
            window.styleMask = [.titled, .closable]
            // Le défaut est `true` et libérerait la fenêtre à la fermeture,
            // laissant `settingsWindow` pointer dans le vide.
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func openHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryView()))
            window.title = "Historique"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        NSApp.activate()
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu de la barre des menus

extension AppDelegate: NSMenuDelegate {
    /// AppKit demande le contenu juste avant l'ouverture : l'état affiché est
    /// donc toujours frais, sans observateur à brancher.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        statusMenu.populate(menu, state: currentMenuState())
    }

    /// Le pourcentage de téléchargement doit bouger pendant que le menu est
    /// ouvert, sinon l'utilisateur voit un chiffre figé et croit que c'est
    /// bloqué. Le timer doit tourner en mode `eventTracking`, le seul actif
    /// pendant le suivi d'un menu.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu, statusMenu.isShowingDownload else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let progress = ModelStore.shared.progress
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .first
                    .map { StatusMenuController.Download(model: $0.value.model, fraction: $0.value.fraction) }
                self.statusMenu.refreshDownload(progress)
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        downloadRefreshTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        downloadRefreshTimer?.invalidate()
        downloadRefreshTimer = nil
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
