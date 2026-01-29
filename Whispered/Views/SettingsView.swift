import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("selectedModel") private var selectedModelRaw = "base"
    @AppStorage("autoLaunch") private var autoLaunch = false
    @AppStorage("popupMode") private var popupModeRaw = PopupMode.standard.rawValue

    @State private var isLoading = false
    @State private var loadingModel: WhisperModel?
    @State private var downloadProgress: Double = 0
    @State private var statusMessage = ""
    @State private var refreshTrigger = false

    // Update states
    @State private var isCheckingUpdate = false
    @State private var availableUpdate: UpdateInfo?
    @State private var updateError: String?
    @State private var isUpdating = false
    @State private var updateProgress: UpdateProgress?

    private var isAppInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Whispered")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Transcription vocale locale")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content
            Form {
                Section("Modèle Whisper") {
                    ForEach(WhisperModel.allCases, id: \.rawValue) { model in
                        ModelRow(
                            model: model,
                            isSelected: selectedModelRaw == model.rawValue,
                            isAvailable: WhisperService.shared.isModelAvailable(model),
                            isLoading: loadingModel == model,
                            onSelect: { selectModel(model) },
                            onDownload: { downloadModel(model) },
                            onDelete: { deleteModel(model) }
                        )
                        .id("\(model.rawValue)-\(refreshTrigger)")
                    }

                    if !statusMessage.isEmpty {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundColor(statusMessage.contains("Erreur") ? .red : .secondary)
                        }
                    }
                }

                Section("Transcription") {
                    Picker("Langue de transcription", selection: $selectedLanguage) {
                        Text("Automatique").tag("auto")
                        Divider()
                        Text("Français").tag("fr")
                        Text("Anglais").tag("en")
                        Text("Espagnol").tag("es")
                        Text("Allemand").tag("de")
                        Text("Italien").tag("it")
                        Text("Portugais").tag("pt")
                        Text("Japonais").tag("ja")
                        Text("Chinois").tag("zh")
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Text("Raccourci clavier")
                        Spacer()
                        Text("⌘ droite (Command droit)")
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Section("Apparence") {
                    Picker("Mode du popup", selection: $popupModeRaw) {
                        ForEach(PopupMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: popupModeRaw) { _, _ in
                        NotificationCenter.default.post(name: .popupModeDidChange, object: nil)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Standard")
                                .fontWeight(.medium)
                            Text("Affichage complet avec animation et aperçu")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("280×220")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(popupModeRaw == PopupMode.standard.rawValue ? 1.0 : 0.5)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Compact")
                                .fontWeight(.medium)
                            Text("Affichage minimal, moins intrusif")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("220×80")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(popupModeRaw == PopupMode.compact.rawValue ? 1.0 : 0.5)
                }

                Section("Système") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Lancer au démarrage", isOn: $autoLaunch)
                            .onChange(of: autoLaunch) { _, newValue in
                                setAutoLaunch(enabled: newValue)
                            }
                            .disabled(!isAppInstalled)

                        if !isAppInstalled {
                            Text("Disponible uniquement si l'app est dans /Applications")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("Dossier des modèles")
                        Spacer()
                        Button("Ouvrir") {
                            openModelsFolder()
                        }
                        .buttonStyle(.link)
                    }
                }

                Section("Mises à jour") {
                    HStack {
                        Text("Version actuelle")
                        Spacer()
                        Text(UpdateService.shared.currentVersion)
                            .foregroundColor(.secondary)
                    }

                    if isCheckingUpdate {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Vérification...")
                                .foregroundColor(.secondary)
                        }
                    } else if isUpdating, let progress = updateProgress {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(progress.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: progress.progress)
                            if progress.phase == .downloading {
                                Button("Annuler") {
                                    UpdateService.shared.cancelUpdate()
                                    isUpdating = false
                                    updateProgress = nil
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    } else if let update = availableUpdate {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.green)
                                Text("Version \(update.version) disponible")
                                    .fontWeight(.medium)
                                Spacer()
                                Text(update.formattedFileSize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let notes = update.releaseNotes, !notes.isEmpty {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }

                            Button("Installer la mise à jour") {
                                installUpdate(update)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if let error = updateError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Réessayer") {
                                checkForUpdate()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    } else {
                        HStack {
                            Text("Aucune mise à jour disponible")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Vérifier") {
                                checkForUpdate()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                Section("À propos") {
                    HStack {
                        Text("Moteur")
                        Spacer()
                        Text("whisper.cpp + CoreML")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com/ggerganov/whisper.cpp")!) {
                        HStack {
                            Text("whisper.cpp sur GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 720)
    }

    private func selectModel(_ model: WhisperModel) {
        guard WhisperService.shared.isModelAvailable(model) else {
            downloadModel(model)
            return
        }

        isLoading = true
        statusMessage = "Chargement de \(model.rawValue)..."

        WhisperService.shared.switchModel(to: model) { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success:
                    selectedModelRaw = model.rawValue
                    statusMessage = ""
                case .failure(let error):
                    statusMessage = "Erreur: \(error.localizedDescription)"
                }
            }
        }
    }

    private func downloadModel(_ model: WhisperModel) {
        isLoading = true
        loadingModel = model
        statusMessage = "Téléchargement de \(model.rawValue)..."

        WhisperService.shared.downloadModel(model) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    statusMessage = "Activation de \(model.rawValue)..."
                    WhisperService.shared.switchModel(to: model) { switchResult in
                        DispatchQueue.main.async {
                            isLoading = false
                            loadingModel = nil
                            switch switchResult {
                            case .success:
                                selectedModelRaw = model.rawValue
                                statusMessage = ""
                                refreshTrigger.toggle()
                            case .failure(let error):
                                statusMessage = "Erreur: \(error.localizedDescription)"
                            }
                        }
                    }
                case .failure(let error):
                    isLoading = false
                    loadingModel = nil
                    statusMessage = "Erreur: \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteModel(_ model: WhisperModel) {
        let result = WhisperService.shared.deleteModel(model)
        switch result {
        case .success:
            statusMessage = "Modèle \(model.rawValue) supprimé"
            refreshTrigger.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                statusMessage = ""
            }
        case .failure(let error):
            statusMessage = "Erreur: \(error.localizedDescription)"
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
            print("Failed to \(enabled ? "enable" : "disable") auto-launch: \(error)")
            // Revert the toggle on error
            DispatchQueue.main.async {
                autoLaunch = !enabled
            }
        }
    }

    private func openModelsFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("Whispered/models")
        NSWorkspace.shared.open(modelsDir)
    }

    // MARK: - Update Methods

    private func checkForUpdate() {
        isCheckingUpdate = true
        updateError = nil
        availableUpdate = nil

        UpdateService.shared.checkForUpdate { result in
            DispatchQueue.main.async {
                isCheckingUpdate = false
                switch result {
                case .success(let update):
                    availableUpdate = update
                case .failure(let error):
                    updateError = error.localizedDescription
                }
            }
        }
    }

    private func installUpdate(_ update: UpdateInfo) {
        isUpdating = true
        updateError = nil

        UpdateService.shared.downloadAndInstall(update: update) { progress in
            // Le progress handler est déjà appelé sur main thread via delegateQueue
            self.updateProgress = progress
        } completion: { result in
            // Le completion est dispatché sur main thread par UpdateService
            switch result {
            case .success:
                // L'app devrait redémarrer, mais si ça échoue, reset l'UI après un délai
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.isUpdating {
                        self.isUpdating = false
                        self.updateProgress = nil
                        self.updateError = "L'application a été mise à jour. Veuillez la relancer manuellement."
                    }
                }
            case .failure(let error):
                self.isUpdating = false
                self.updateProgress = nil
                if case .cancelled = error {
                    // Annulation utilisateur, pas d'erreur à afficher
                } else {
                    self.updateError = error.localizedDescription
                }
            }
        }
    }
}

struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let isAvailable: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.rawValue.capitalized)
                        .fontWeight(isSelected ? .semibold : .regular)

                    if isSelected {
                        Text("actif")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 4) {
                    Text(modelDescription(model))
                    if isAvailable, let size = WhisperService.shared.getModelSize(model) {
                        Text("•")
                        Text(size)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Status / Actions
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if isAvailable {
                HStack(spacing: 8) {
                    if !isSelected {
                        Button("Utiliser") {
                            onSelect()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Supprimer le modèle")
                    }
                }
            } else {
                Button("Télécharger") {
                    onDownload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isAvailable && !isSelected {
                onSelect()
            } else if !isAvailable {
                onDownload()
            }
        }
        .alert("Supprimer le modèle ?", isPresented: $showDeleteConfirmation) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("Le modèle \(model.rawValue.capitalized) sera supprimé. Vous pourrez le retélécharger plus tard.")
        }
    }

    private func modelDescription(_ model: WhisperModel) -> String {
        switch model {
        case .tiny:
            return "~75 MB • Très rapide, moins précis"
        case .base:
            return "~150 MB • Bon équilibre vitesse/qualité"
        case .small:
            return "~500 MB • Précis, recommandé"
        case .medium:
            return "~1.5 GB • Très précis, plus lent"
        }
    }
}
