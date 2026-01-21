import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("selectedModel") private var selectedModelRaw = "base"
    @AppStorage("autoLaunch") private var autoLaunch = false

    @State private var isLoading = false
    @State private var loadingModel: WhisperModel?
    @State private var downloadProgress: Double = 0
    @State private var statusMessage = ""
    @State private var refreshTrigger = false

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
                            onDownload: { downloadModel(model) }
                        )
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

                Section("Système") {
                    Toggle("Lancer au démarrage", isOn: $autoLaunch)
                        .onChange(of: autoLaunch) { _, newValue in
                            setAutoLaunch(enabled: newValue)
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

                Section("À propos") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

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
        .frame(width: 500, height: 520)
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

    private func setAutoLaunch(enabled: Bool) {
        // TODO: Implement with SMAppService
    }

    private func openModelsFolder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("Whispered/models")
        NSWorkspace.shared.open(modelsDir)
    }
}

struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let isAvailable: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

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

                Text(modelDescription(model))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status / Actions
            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else if isAvailable {
                if !isSelected {
                    Button("Utiliser") {
                        onSelect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
