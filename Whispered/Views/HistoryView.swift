import SwiftUI
import AppKit

/// Fenêtre d'historique : retrouver, copier ou réinsérer une dictée passée.
struct HistoryView: View {
    @ObservedObject private var history = TranscriptionHistory.shared
    @State private var query = ""
    @State private var selection: TranscriptionEntry.ID?
    @State private var showClearConfirmation = false

    private var visibleEntries: [TranscriptionEntry] {
        history.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if history.entries.isEmpty {
                emptyState
            } else if visibleEntries.isEmpty {
                noResultState
            } else {
                List(visibleEntries, selection: $selection) { entry in
                    HistoryRow(entry: entry)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }

            Divider()

            footer
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 360, idealHeight: 520)
    }

    // MARK: - Sous-vues

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Historique des dictées")
                    .font(.headline)
                Text("\(history.entries.count) sur \(TranscriptionHistory.maxEntries) conservées, en local uniquement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Rechercher", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(12)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Aucune dictée", systemImage: "waveform")
        } description: {
            Text(history.isEnabled
                 ? "Les dictées apparaîtront ici dès la prochaine transcription."
                 : "La conservation de l'historique est désactivée.")
        }
        .frame(maxHeight: .infinity)
    }

    private var noResultState: some View {
        ContentUnavailableView.search(text: query)
            .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Toggle("Conserver l'historique", isOn: $history.isEnabled)
                .toggleStyle(.checkbox)
                .help("Désactivé, rien n'est écrit sur le disque et l'historique existant est effacé.")
            Spacer()
            Button("Tout effacer") {
                showClearConfirmation = true
            }
            .disabled(history.entries.isEmpty)
        }
        .padding(12)
        .confirmationDialog(
            "Effacer tout l'historique ?",
            isPresented: $showClearConfirmation
        ) {
            Button("Effacer", role: .destructive) { history.clear() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les \(history.entries.count) dictées conservées seront supprimées. C'est définitif.")
        }
    }
}

// MARK: - Ligne d'historique

private struct HistoryRow: View {
    let entry: TranscriptionEntry
    @State private var isHovering = false
    @State private var justCopied = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(entry.engine)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: Capsule())

                if let lang = entry.language, lang != "auto" {
                    Text(lang.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let factor = entry.realtimeFactor {
                    Text(String(format: "%.0f× temps réel", factor))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(String(format: "%.2f s d'audio transcrites en %.0f ms",
                                     entry.audioDuration, entry.processingTime * 1000))
                }

                Spacer()

                if isHovering || justCopied {
                    actions
                }
            }
        }
        .padding(.vertical, 5)
        .onHover { isHovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                copy()
            } label: {
                Label(justCopied ? "Copié" : "Copier",
                      systemImage: justCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.link)
            .font(.caption)

            Button {
                TextInjector.shared.inject(entry.text)
            } label: {
                Label("Réinsérer", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.link)
            .font(.caption)
            .help("Insère ce texte dans l'application active")

            Button(role: .destructive) {
                TranscriptionHistory.shared.remove(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
    }
}
