import Foundation
import SwiftUI

/// État partagé entre l'AppDelegate et le popup d'enregistrement.
@MainActor
final class RecordingState: ObservableObject {
    @Published var isRecording = false
    @Published var statusText = "Prêt"
    @Published var lastTranscription = ""

    /// Texte en cours de construction pendant la dictée, quand le moteur
    /// système est activé : il donne un premier mot 26 ms après la parole.
    @Published var liveText = ""

    /// Niveau du micro normalisé entre 0 et 1, le plus récent en dernier.
    /// Alimenté pendant l'enregistrement pour dessiner l'onde : sans ce retour,
    /// un micro muet ou mal sélectionné ne se voit qu'après la dictée.
    @Published var levels: [Float] = []

    /// Nombre de barres affichées par l'onde
    static let levelCount = 44

    func appendLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        levels.append(clamped)
        if levels.count > Self.levelCount {
            levels.removeFirst(levels.count - Self.levelCount)
        }
    }

    func resetLevels() {
        levels.removeAll()
    }
}
