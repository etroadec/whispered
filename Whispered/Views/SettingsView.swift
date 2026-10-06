import ServiceManagement
import SwiftUI

/// Préférences, découpées en onglets façon macOS.
///
/// Avant : un seul formulaire déclaré en 500×950 dans une fenêtre dimensionnée
/// à 500×850, donc tronqué, où le choix du modèle, la langue, le raccourci et
/// les mises à jour se bousculaient.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, engine, hotkeys, corrections, updates

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "Général"
            case .engine: return "Moteur"
            case .hotkeys: return "Raccourcis"
            case .corrections: return "Dictionnaire"
            case .updates: return "Mises à jour"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .engine: return "cpu"
            case .hotkeys: return "keyboard"
            case .corrections: return "text.badge.checkmark"
            case .updates: return "arrow.down.circle"
            }
        }
    }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(tab)
            }
        }
        .frame(width: 540, height: 560)
    }

    @ViewBuilder
    private func content(for tab: Tab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .engine: EngineSettings()
        case .hotkeys: HotkeySettings()
        case .corrections: ScrollView { CorrectionsView().padding(20) }
        case .updates: UpdateSettings()
        }
    }
}

// MARK: - Général

private struct GeneralSettings: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("livePreviewEnabled") private var livePreviewEnabled = true
    @AppStorage("translateToEnglish") private var translateToEnglish = false
    @AppStorage("insertionMode") private var insertionModeRaw = InsertionMode.direct.rawValue
    @AppStorage("popupMode") private var popupModeRaw = PopupMode.standard.rawValue
    @AppStorage("autoLaunch") private var autoLaunch = false
    @ObservedObject private var history = TranscriptionHistory.shared
    @State private var favorites: [String] = FavoriteLanguagesManager.shared.favorites

    private var isAppInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications")
    }

    /// Le moteur système n'existe qu'à partir de macOS 26 et sur Apple Silicon
    private var isLivePreviewAvailable: Bool {
        if #available(macOS 26.0, *) {
            return AppleSpeechEngine.isSupported
        }
        return false
    }

    /// Parakeet détecte la langue tout seul : le choix n'a aucun effet sur lui
    private var languageSelectionApplies: Bool {
        TranscriptionService.shared.currentModel.supportsLanguageSelection
    }

    var body: some View {
        Form {
            Section("Langue") {
                Picker("Langue de transcription", selection: $selectedLanguage) {
                    Text("🌐 Automatique").tag("auto")
                    Divider()
                    ForEach(Language.allLanguages) { lang in
                        Text(lang.displayName).tag(lang.code)
                    }
                }
                .disabled(!languageSelectionApplies)
                .onChange(of: selectedLanguage) { _, newValue in
                    NotificationCenter.default.post(name: .selectedLanguageDidChange, object: newValue)
                }

                if !languageSelectionApplies {
                    Text("Parakeet reconnaît la langue tout seul parmi 25 langues européennes : ce choix ne s'applique qu'au moteur Whisper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("Traduire en anglais", isOn: $translateToEnglish)
                    Text("Whisper traduit pendant la transcription : tu dictes en français, le texte inséré est en anglais.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Favorites")
                        Spacer()
                        Text("\(favorites.count)/2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Accessibles directement depuis l'icône de la barre des menus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(Language.allLanguages) { lang in
                            FavoriteLanguageToggle(
                                language: lang,
                                isSelected: favorites.contains(lang.code),
                                isDisabled: !favorites.contains(lang.code) && favorites.count >= 2
                            ) {
                                FavoriteLanguagesManager.shared.toggleFavorite(lang.code)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Insertion du texte") {
                Picker("À la fin de la dictée", selection: $insertionModeRaw) {
                    ForEach(InsertionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Text(InsertionMode(rawValue: insertionModeRaw)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Dans un champ de mot de passe, macOS bloque l'insertion automatique : le texte est alors copié, et le popup le dit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLivePreviewAvailable {
                Section("Pendant la dictée") {
                    Toggle("Afficher le texte au fil de la parole", isOn: $livePreviewEnabled)
                    Text("Le moteur de transcription de macOS affiche le texte pendant que tu parles, environ 30 ms après chaque mot. Le texte finalement inséré reste celui de ton moteur, plus fidèle sur la ponctuation et le jargon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Popup") {
                Picker("Taille", selection: $popupModeRaw) {
                    ForEach(PopupMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: popupModeRaw) { _, _ in
                    NotificationCenter.default.post(name: .popupModeDidChange, object: nil)
                }
                Text("Le popup affiche l'onde du micro pendant la dictée : si les barres restent plates, c'est que rien n'entre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Historique") {
                Toggle("Conserver les dictées", isOn: $history.isEnabled)
                Text("Les \(TranscriptionHistory.maxEntries) dernières dictées, en local. Accessible depuis la barre des menus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Système") {
                Toggle("Lancer au démarrage", isOn: $autoLaunch)
                    .onChange(of: autoLaunch) { _, newValue in
                        setAutoLaunch(enabled: newValue)
                    }
                    .disabled(!isAppInstalled)
                if !isAppInstalled {
                    Text("Disponible uniquement si l'app est dans /Applications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .favoriteLanguagesDidChange)) { _ in
            favorites = FavoriteLanguagesManager.shared.favorites
        }
    }

    private func setAutoLaunch(enabled: Bool) {
        guard isAppInstalled else { return }
        do {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            autoLaunch = !enabled
        }
    }
}

// MARK: - Raccourcis

private struct HotkeySettings: View {
    @AppStorage("hotkeyChoice") private var hotkeyChoiceRaw = HotkeyChoice.rightCommand.rawValue
    @AppStorage("recordingMode") private var recordingModeRaw = RecordingMode.hold.rawValue
    @AppStorage("secondaryHotkeyChoice") private var secondaryRaw = ""
    @AppStorage("secondaryAction") private var secondaryActionRaw = SecondaryAction.alternateEngine.rawValue
    @AppStorage("reformulationStyle") private var reformulationStyleRaw = ReformulationStyle.clean.rawValue

    private let noneTag = ""

    var body: some View {
        Form {
            Section("Raccourci principal") {
                Picker("Touche", selection: $hotkeyChoiceRaw) {
                    ForEach(HotkeyChoice.groupedByCategory, id: \.category) { group in
                        Section(header: Text(group.category)) {
                            ForEach(group.choices) { choice in
                                Text(choice.displayName).tag(choice.rawValue)
                            }
                        }
                    }
                }
                .onChange(of: hotkeyChoiceRaw) { _, newValue in
                    if let choice = HotkeyChoice(rawValue: newValue) {
                        HotkeySettingsManager.shared.hotkeyChoice = choice
                        // Le second raccourci ne peut pas être la même touche
                        if secondaryRaw == newValue { secondaryRaw = noneTag }
                    }
                }

                Picker("Mode", selection: $recordingModeRaw) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: recordingModeRaw) { _, newValue in
                    if let mode = RecordingMode(rawValue: newValue) {
                        HotkeySettingsManager.shared.recordingMode = mode
                    }
                }

                Text(RecordingMode(rawValue: recordingModeRaw)?.description ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Second raccourci") {
                Picker("Touche", selection: $secondaryRaw) {
                    Text("Aucun").tag(noneTag)
                    Divider()
                    ForEach(HotkeyChoice.groupedByCategory, id: \.category) { group in
                        Section(header: Text(group.category)) {
                            ForEach(group.choices.filter { $0.rawValue != hotkeyChoiceRaw }) { choice in
                                Text(choice.displayName).tag(choice.rawValue)
                            }
                        }
                    }
                }
                .onChange(of: secondaryRaw) { _, newValue in
                    HotkeySettingsManager.shared.secondaryHotkeyChoice = HotkeyChoice(rawValue: newValue)
                }

                Picker("Action", selection: $secondaryActionRaw) {
                    ForEach(SecondaryAction.allCases) { action in
                        Text(action.displayName).tag(action.rawValue)
                    }
                }
                .disabled(secondaryRaw == noneTag)
                .onChange(of: secondaryActionRaw) { _, newValue in
                    if let action = SecondaryAction(rawValue: newValue) {
                        HotkeySettingsManager.shared.secondaryAction = action
                    }
                }

                Text(SecondaryAction(rawValue: secondaryActionRaw)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if secondaryActionRaw == SecondaryAction.reformulate.rawValue {
                reformulationSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var reformulationSection: some View {
        Section("Réécriture") {
            Picker("Style", selection: $reformulationStyleRaw) {
                ForEach(ReformulationStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .onChange(of: reformulationStyleRaw) { _, newValue in
                HotkeySettingsManager.shared.reformulationStyle = newValue
            }

            Text(ReformulationStyle(rawValue: reformulationStyleRaw)?.detail ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if #available(macOS 26.0, *) {
                let availability = TextReformulator.availability
                HStack(spacing: 6) {
                    Image(systemName: availability.isReady
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(availability.isReady ? .green : .orange)
                    Text(availability.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("La réécriture demande macOS 26.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Mises à jour

private struct UpdateSettings: View {
    @State private var isChecking = false
    @State private var available: UpdateInfo?
    @State private var errorMessage: String?
    @State private var isUpdating = false
    @State private var progress: UpdateProgress?

    var body: some View {
        Form {
            Section("Version") {
                HStack {
                    Text("Version installée")
                    Spacer()
                    Text(UpdateService.shared.currentVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if isChecking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Vérification…").foregroundStyle(.secondary)
                    }
                } else if isUpdating, let progress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(progress.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: progress.progress)
                        if progress.phase == .downloading {
                            Button("Annuler") {
                                UpdateService.shared.cancelUpdate()
                                isUpdating = false
                                self.progress = nil
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                } else if let update = available {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                            Text("Version \(update.version) disponible")
                                .fontWeight(.medium)
                            Spacer()
                            Text(update.formattedFileSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let notes = update.releaseNotes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(5)
                        }
                        Button("Installer") { install(update) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack {
                        Text(errorMessage ?? "Aucune mise à jour disponible")
                            .foregroundStyle(errorMessage == nil ? .secondary : .primary)
                            .font(errorMessage == nil ? .body : .caption)
                        Spacer()
                        Button(errorMessage == nil ? "Vérifier" : "Réessayer") { check() }
                            .buttonStyle(.link)
                    }
                }
            }

            Section("Sécurité") {
                Label("L'archive est vérifiée par empreinte SHA-256, et le bundle doit être signé par le même signataire que l'app installée.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("À propos") {
                HStack {
                    Text("Moteurs")
                    Spacer()
                    Text("Parakeet TDT v3 · whisper.cpp")
                        .foregroundStyle(.secondary)
                }
                Link(destination: URL(string: "https://github.com/ggml-org/whisper.cpp")!) {
                    HStack {
                        Text("whisper.cpp")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                Text("Modèle Parakeet TDT 0.6B v3 de NVIDIA, licence CC-BY-4.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func check() {
        isChecking = true
        errorMessage = nil
        available = nil
        UpdateService.shared.checkForUpdate { result in
            Task { @MainActor in
                isChecking = false
                switch result {
                case .success(let update): available = update
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func install(_ update: UpdateInfo) {
        isUpdating = true
        errorMessage = nil
        UpdateService.shared.downloadAndInstall(update: update) { progress in
            Task { @MainActor in self.progress = progress }
        } completion: { result in
            Task { @MainActor in
                switch result {
                case .success:
                    try? await Task.sleep(for: .seconds(3))
                    if isUpdating {
                        isUpdating = false
                        progress = nil
                        errorMessage = "Mise à jour installée. Relance l'application."
                    }
                case .failure(let error):
                    isUpdating = false
                    progress = nil
                    if case .cancelled = error { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Bouton de langue favorite

struct FavoriteLanguageToggle: View {
    let language: Language
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(language.flag)
                Text(language.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}
