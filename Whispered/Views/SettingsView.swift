import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedLanguage") private var selectedLanguage = "auto"
    @AppStorage("autoLaunch") private var autoLaunch = false

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Langue", selection: $selectedLanguage) {
                    Text("Automatique").tag("auto")
                    Text("Français").tag("fr")
                    Text("Anglais").tag("en")
                    Text("Espagnol").tag("es")
                    Text("Allemand").tag("de")
                    Text("Italien").tag("it")
                }

                LabeledContent("Raccourci") {
                    Text("⌘ droite")
                        .foregroundColor(.secondary)
                }
            }

            Section("Général") {
                Toggle("Lancer au démarrage", isOn: $autoLaunch)
                    .onChange(of: autoLaunch) { _, newValue in
                        setAutoLaunch(enabled: newValue)
                    }
            }

            Section("Modèle") {
                LabeledContent("Modèle actuel") {
                    Text("Whisper Base")
                        .foregroundColor(.secondary)
                }

                Button("Retélécharger le modèle") {
                    WhisperService.shared.downloadModelIfNeeded { _ in }
                }
            }

            Section("À propos") {
                LabeledContent("Version") {
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }

                Link("whisper.cpp sur GitHub",
                     destination: URL(string: "https://github.com/ggerganov/whisper.cpp")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 350)
    }

    private func setAutoLaunch(enabled: Bool) {
        // Implementation for login item would go here
        // Requires SMAppService for modern macOS
    }
}
