import SwiftUI

/// Onglet « Moteur » : choix du modèle, téléchargement, ménage.
struct EngineSettings: View {
    @ObservedObject private var service = TranscriptionService.shared
    @ObservedObject private var store = ModelStore.shared

    @State private var message: String?
    @State private var isError = false

    var body: some View {
        Form {
            modelSection
            vadSection
            ReclaimableSpaceSection(store: store)
            folderSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Modèles

    private var modelSection: some View {
        Section("Modèle actif") {
            ForEach(TranscriptionModel.allCases) { model in
                ModelRow(
                    model: model,
                    isSelected: service.currentModel == model,
                    isInstalled: ModelStore.isInstalled(model),
                    isLoading: service.loadingModel == model,
                    progress: store.progress[model],
                    installedSize: store.installedSize(of: model),
                    onSelect: { select(model) },
                    onDownload: { download(model) },
                    onCancel: { store.cancel(model) },
                    onDelete: { delete(model) }
                )
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
            }
        }
    }

    // MARK: - VAD

    private var vadSection: some View {
        Section("Détection de parole") {
            HStack(spacing: 10) {
                Image(systemName: VoiceActivityDetector.shared.isModelInstalled
                      ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(VoiceActivityDetector.shared.isModelInstalled ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Silero VAD")
                    Text("0,9 Mo. Évite de transcrire le silence et rogne les blancs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !VoiceActivityDetector.shared.isModelInstalled {
                    Button("Télécharger") { store.downloadVADModelIfNeeded() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Dossier

    private var folderSection: some View {
        Section("Dossier") {
            HStack {
                Text("Modèles installés")
                Spacer()
                Button("Ouvrir") {
                    NSWorkspace.shared.open(ModelStore.modelsDirectory)
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Actions

    private func select(_ model: TranscriptionModel) {
        guard ModelStore.isInstalled(model) else {
            download(model)
            return
        }
        service.select(model: model)
        message = nil
    }

    private func download(_ model: TranscriptionModel) {
        message = nil
        store.download(model) { result in
            switch result {
            case .success:
                isError = false
                message = "\(model.displayName) installé."
                service.select(model: model)
            case .failure(let error):
                if case .cancelled = error {
                    message = nil
                    return
                }
                isError = true
                message = error.localizedDescription
            }
        }
    }

    private func delete(_ model: TranscriptionModel) {
        do {
            try store.delete(model)
            isError = false
            message = "\(model.displayName) supprimé."
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}

// MARK: - Place à récupérer

private struct ReclaimableSpaceSection: View {
    @ObservedObject var store: ModelStore

    @State private var files: [(name: String, bytes: Int64)] = []
    @State private var pendingDeletion: String?

    var body: some View {
        Group {
            if !files.isEmpty {
                Section("Place à récupérer") {
                    Text("Ces fichiers occupent le dossier des modèles sans servir à l'app : anciens modèles, encodeurs CoreML devenus inutiles, téléchargements interrompus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(files, id: \.name) { file in
                        FileRow(
                            name: file.name,
                            bytes: file.bytes,
                            onReveal: { store.revealInFinder(file.name) },
                            onDelete: { pendingDeletion = file.name }
                        )
                    }

                    HStack {
                        Text("Total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.formatted(files.reduce(0) { $0 + $1.bytes }))
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
        }
        .onAppear { refresh() }
        .alert(
            "Supprimer \(pendingDeletion ?? "") ?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            )
        ) {
            Button("Annuler", role: .cancel) { pendingDeletion = nil }
            Button("Supprimer", role: .destructive) {
                if let name = pendingDeletion {
                    try? store.deleteRetiredFile(named: name)
                }
                pendingDeletion = nil
                refresh()
            }
        } message: {
            Text("Le fichier sera effacé du disque. Il reste téléchargeable si besoin.")
        }
    }

    private func refresh() {
        files = store.retiredModelFiles()
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct FileRow: View {
    let name: String
    let bytes: Int64
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(ReclaimableSpaceSection.formatted(bytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Révéler dans le Finder")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Supprimer")
        }
    }
}

// MARK: - Ligne de modèle

private struct ModelRow: View {
    let model: TranscriptionModel
    let isSelected: Bool
    let isInstalled: Bool
    let isLoading: Bool
    let progress: ModelDownloadProgress?
    let installedSize: String?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.system(size: 15))

                info

                Spacer()

                actions
            }

            if let progress {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text(progress.description)
                        Spacer()
                        Text("\(Int(progress.fraction * 100)) %")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isInstalled && !isSelected { onSelect() }
        }
        .alert("Supprimer \(model.displayName) ?", isPresented: $showDeleteConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive, action: onDelete)
        } message: {
            Text("Le fichier sera effacé du disque. Tu pourras le retélécharger.")
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(model.engine.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())
                if isSelected {
                    Text("actif")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(installedSize ?? model.formattedSize)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var actions: some View {
        if progress != nil {
            Button("Annuler", action: onCancel)
                .controlSize(.small)
        } else if isLoading {
            ProgressView().controlSize(.small)
        } else if isInstalled {
            HStack(spacing: 6) {
                if !isSelected {
                    Button("Utiliser", action: onSelect)
                        .controlSize(.small)
                }
                // Corbeille toujours visible, désactivée sur le modèle actif :
                // sans ça, rien n'expliquait pourquoi on ne pouvait pas libérer
                // les 638 Mo du modèle en cours d'usage.
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isSelected)
                .help(isSelected
                      ? "Choisis d'abord un autre modèle pour pouvoir supprimer celui-ci"
                      : "Supprimer le modèle")
            }
        } else {
            Button("Télécharger", action: onDownload)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }
}
