import SwiftUI

/// Fenêtre de premier lancement : les deux permissions, la langue, le raccourci.
///
/// Avant, l'app se lançait en silence et interrogeait l'accessibilité une fois
/// par seconde en attendant que l'utilisateur devine quoi faire.
struct OnboardingView: View {
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("hotkeyChoice") private var hotkeyChoiceRaw = HotkeyChoice.rightCommand.rawValue
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    /// Appelé quand l'utilisateur termine : l'AppDelegate ferme la fenêtre
    var onFinish: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    permissionsSection
                    settingsSection
                    usageSection
                }
                .padding(22)
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 600)
        .onAppear {
            permissions.refresh()
            permissions.startMonitoring()
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bienvenue dans Whispered")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Dictée vocale locale : rien ne quitte ton Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(22)
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Deux autorisations", systemImage: "lock.shield")

            PermissionRow(
                title: "Microphone",
                detail: "Pour enregistrer ta voix.",
                state: permissions.microphone,
                primaryLabel: "Autoriser",
                primaryAction: { Task { await permissions.requestMicrophone() } },
                settingsAction: permissions.openMicrophoneSettings
            )

            PermissionRow(
                title: "Accessibilité",
                detail: "Pour détecter le raccourci clavier et insérer le texte.",
                state: permissions.accessibility,
                primaryLabel: "Autoriser",
                primaryAction: permissions.promptAccessibility,
                settingsAction: permissions.openAccessibilitySettings
            )

            if !permissions.allGranted {
                Text("Après avoir coché Whispered dans Réglages Système, reviens ici : la case se met à jour toute seule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Réglages de base

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Réglages de départ", systemImage: "slider.horizontal.3")

            Picker("Langue", selection: $selectedLanguage) {
                Text("🌐 Automatique").tag("auto")
                Divider()
                ForEach(Language.allLanguages) { lang in
                    Text(lang.displayName).tag(lang.code)
                }
            }

            Picker("Raccourci", selection: $hotkeyChoiceRaw) {
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
                }
            }
        }
    }

    // MARK: - Mode d'emploi

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Comment ça marche", systemImage: "hand.tap")

            let key = HotkeyChoice(rawValue: hotkeyChoiceRaw)?.fullDescription ?? "⌘ droite"
            StepRow(number: 1, text: "Maintiens **\(key)** enfoncée.")
            StepRow(number: 2, text: "Parle normalement.")
            StepRow(number: 3, text: "Relâche : le texte apparaît là où est ton curseur.")

            Text("L'icône d'onde dans la barre des menus donne accès à la langue, à l'historique et aux préférences.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pied

    private var footer: some View {
        HStack {
            if permissions.allGranted {
                Label("Tout est prêt", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Text("Les autorisations manquantes peuvent être accordées plus tard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Commencer") {
                onboardingCompleted = true
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }
}

// MARK: - Ligne de permission

private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: Permissions.State
    let primaryLabel: String
    let primaryAction: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17))
                .foregroundStyle(state.isGranted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !state.isGranted {
                switch state {
                case .notRequested:
                    Button(primaryLabel, action: primaryAction)
                        .controlSize(.small)
                case .denied:
                    Button("Réglages Système…", action: settingsAction)
                        .controlSize(.small)
                case .granted:
                    EmptyView()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Étape numérotée

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .frame(width: 18, height: 18)
                .background(.tint.opacity(0.15), in: Circle())
            Text(.init(text))
                .font(.callout)
            Spacer()
        }
    }
}
