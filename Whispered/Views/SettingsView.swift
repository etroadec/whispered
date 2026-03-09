import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("selectedModel") private var selectedModelRaw = "base"
    @AppStorage("autoLaunch") private var autoLaunch = false
    @AppStorage("popupMode") private var popupModeRaw = PopupMode.standard.rawValue
    @AppStorage("hotkeyChoice") private var hotkeyChoiceRaw = HotkeyChoice.rightCommand.rawValue
    @AppStorage("recordingMode") private var recordingModeRaw = RecordingMode.hold.rawValue
    
    @State private var isLoading = false
    @State private var loadingModel: WhisperModel?
    @State private var downloadProgress: Double = 0
    @State private var statusMessage = ""
    @State private var refreshTrigger = false
    
    // Favorite languages state
    @State private var favoriteLanguages: [String] = FavoriteLanguagesManager.shared.favorites
    
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
                Section("Modele Whisper") {
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
                        Text("🌐 Automatique").tag("auto")
                        Divider()
                        ForEach(Language.allLanguages) { lang in
                            Text(lang.displayName).tag(lang.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedLanguage) { _, newValue in
                        NotificationCenter.default.post(name: .selectedLanguageDidChange, object: newValue)
                    }
                    
                    // Langues favorites
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Langues favorites")
                            Spacer()
                            Text("\(favoriteLanguages.count)/2")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Apparaissent dans le menu contextuel pour un acces rapide")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        // Grid de selection des favoris
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            ForEach(Language.allLanguages) { lang in
                                FavoriteLanguageToggle(
                                    language: lang,
                                    isSelected: favoriteLanguages.contains(lang.code),
                                    isDisabled: !favoriteLanguages.contains(lang.code) && favoriteLanguages.count >= 2
                                ) {
                                    toggleFavorite(lang.code)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                Section("Raccourci clavier") {
                    Picker("Touche", selection: $hotkeyChoiceRaw) {
                        ForEach(HotkeyChoice.groupedByCategory, id: \.category) { group in
                            Section(header: Text(group.category)) {
                                ForEach(group.choices) { choice in
                                    Text(choice.displayName).tag(choice.rawValue)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: hotkeyChoiceRaw) { _, newValue in
                        if let choice = HotkeyChoice(rawValue: newValue) {
                            HotkeySettingsManager.shared.hotkeyChoice = choice
                        }
                    }

                    // Affichage de la touche sélectionnée
                    if let choice = HotkeyChoice(rawValue: hotkeyChoiceRaw) {
                        HStack {
                            Text("Touche sélectionnée :")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(choice.fullDescription)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }
                    
                    Picker("Mode d'enregistrement", selection: $recordingModeRaw) {
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
                    
                    // Description du mode selectionne
                    HStack {
                        Image(systemName: recordingModeRaw == RecordingMode.hold.rawValue ? "hand.tap" : "square.and.arrow.down.on.square")
                            .foregroundColor(.secondary)
                        Text(RecordingMode(rawValue: recordingModeRaw)?.description ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
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
                            Text("Affichage complet avec animation et apercu")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("280x220")
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
                        Text("220x80")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(popupModeRaw == PopupMode.compact.rawValue ? 1.0 : 0.5)
                }
                
                Section("Systeme") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Lancer au demarrage", isOn: $autoLaunch)
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
                        Text("Dossier des modeles")
                        Spacer()
                        Button("Ouvrir") {
                            openModelsFolder()
                        }
                        .buttonStyle(.link)
                    }
                }
                
                Section("Mises a jour") {
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
                            Text("Verification...")
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
                            
                            Button("Installer la mise a jour") {
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
                            Button("Reessayer") {
                                checkForUpdate()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    } else {
                        HStack {
                            Text("Aucune mise a jour disponible")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Verifier") {
                                checkForUpdate()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                
                Section("A propos") {
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
        .frame(width: 500, height: 950)
        .onReceive(NotificationCenter.default.publisher(for: .favoriteLanguagesDidChange)) { _ in
            favoriteLanguages = FavoriteLanguagesManager.shared.favorites
        }
    }
    
    // MARK: - Favorite Languages
    
    private func toggleFavorite(_ code: String) {
        FavoriteLanguagesManager.shared.toggleFavorite(code)
        // L'observer onReceive va automatiquement mettre à jour favoriteLanguages
    }
    
    // MARK: - Model Management
    
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
        statusMessage = "Telechargement de \(model.rawValue)..."
        
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
            statusMessage = "Modele \(model.rawValue) supprime"
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
            // Le progress handler est deja appele sur main thread via delegateQueue
            self.updateProgress = progress
        } completion: { result in
            // Le completion est dispatche sur main thread par UpdateService
            switch result {
            case .success:
                // L'app devrait redemarrer, mais si ca echoue, reset l'UI apres un delai
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.isUpdating {
                        self.isUpdating = false
                        self.updateProgress = nil
                        self.updateError = "L'application a ete mise a jour. Veuillez la relancer manuellement."
                    }
                }
            case .failure(let error):
                self.isUpdating = false
                self.updateProgress = nil
                if case .cancelled = error {
                    // Annulation utilisateur, pas d'erreur a afficher
                } else {
                    self.updateError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Favorite Language Toggle Button

struct FavoriteLanguageToggle: View {
    let language: Language
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(language.flag)
                    .font(.system(size: 14))
                Text(language.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Model Row

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
                        Text("*")
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
                        .help("Supprimer le modele")
                    }
                }
            } else {
                Button("Telecharger") {
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
        .alert("Supprimer le modele ?", isPresented: $showDeleteConfirmation) {
            Button("Annuler", role: .cancel) { }
            Button("Supprimer", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("Le modele \(model.rawValue.capitalized) sera supprime. Vous pourrez le retelecharger plus tard.")
        }
    }
    
    private func modelDescription(_ model: WhisperModel) -> String {
        switch model {
        case .tiny:
            return "~75 MB - Tres rapide, moins precis"
        case .base:
            return "~150 MB - Bon equilibre vitesse/qualite"
        case .small:
            return "~500 MB - Precis, recommande"
        case .medium:
            return "~1.5 GB - Tres precis, plus lent"
        case .largeV3TurboQ5:
            return "~574 MB - Rapide et precis, quantise"
        case .largeV3Turbo:
            return "~1.6 GB - Haute qualite, rapide"
        case .largeV3Q5:
            return "~1.1 GB - Meilleure precision, quantise"
        }
    }
}
