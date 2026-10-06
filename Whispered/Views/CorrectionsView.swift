import SwiftUI

/// Éditeur du dictionnaire de corrections appliqué après transcription.
struct CorrectionsView: View {
    @ObservedObject private var corrections = TextCorrections.shared
    @State private var editing: CorrectionRule?
    @State private var showResetConfirmation = false
    @State private var testInput = "J'ai poussé le pool request sur git hub"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Appliquer les corrections", isOn: $corrections.isEnabled)
                .toggleStyle(.switch)

            Text("Aucun moteur n'écrit correctement les noms propres dictés à la française. Ces règles sont appliquées dans l'ordre, juste avant l'insertion du texte.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            rulesList

            HStack {
                Button {
                    let rule = CorrectionRule(pattern: "", replacement: "")
                    corrections.add(rule)
                    editing = rule
                } label: {
                    Label("Ajouter une règle", systemImage: "plus")
                }

                Spacer()

                Button("Réinitialiser") {
                    showResetConfirmation = true
                }
                .buttonStyle(.link)
            }

            Divider()

            testArea
        }
        .opacity(corrections.isEnabled ? 1 : 0.6)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { updated in
                corrections.update(updated)
            } onDelete: {
                corrections.remove(rule)
            }
        }
        .confirmationDialog("Réinitialiser le dictionnaire ?", isPresented: $showResetConfirmation) {
            Button("Réinitialiser", role: .destructive) { corrections.resetToDefaults() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Tes règles personnalisées seront remplacées par les règles par défaut.")
        }
    }

    // MARK: - Liste

    private var rulesList: some View {
        VStack(spacing: 0) {
            if corrections.rules.isEmpty {
                Text("Aucune règle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(corrections.rules) { rule in
                    RuleRow(rule: rule) {
                        editing = rule
                    } onToggle: { enabled in
                        var copy = rule
                        copy.isEnabled = enabled
                        corrections.update(copy)
                    }
                    if rule.id != corrections.rules.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Zone d'essai

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Essayer")
                .font(.subheadline)
                .fontWeight(.medium)
            TextField("Texte à corriger", text: $testInput)
                .textFieldStyle(.roundedBorder)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(corrections.apply(to: testInput))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Ligne de règle

private struct RuleRow: View {
    let rule: CorrectionRule
    let onEdit: () -> Void
    let onToggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { onToggle($0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)

            Text(rule.pattern.isEmpty ? "(vide)" : rule.pattern)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(rule.replacement)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if rule.isRegex {
                Text(".*")
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    .help("Expression régulière")
            }

            if rule.validationError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(rule.validationError ?? "")
            }

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(rule.isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
    }
}

// MARK: - Éditeur de règle

private struct RuleEditor: View {
    @State private var draft: CorrectionRule
    @Environment(\.dismiss) private var dismiss
    private let onSave: (CorrectionRule) -> Void
    private let onDelete: () -> Void

    init(rule: CorrectionRule, onSave: @escaping (CorrectionRule) -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Règle de correction")
                .font(.headline)

            Form {
                TextField("Chercher", text: $draft.pattern, prompt: Text("pool request"))
                TextField("Remplacer par", text: $draft.replacement, prompt: Text("pull request"))
                Toggle("Expression régulière", isOn: $draft.isRegex)
                Toggle("Mots entiers seulement", isOn: $draft.wholeWordsOnly)
                    .disabled(draft.isRegex)
                Toggle("Ignorer la casse", isOn: $draft.ignoresCase)
            }
            .formStyle(.grouped)

            if let error = draft.validationError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Supprimer", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                Button("Enregistrer") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationError != nil)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
