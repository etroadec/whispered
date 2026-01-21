import Foundation
import SwiftUI

class RecordingState: ObservableObject {
    @Published var isRecording = false
    @Published var statusText = "Prêt"
    @Published var lastTranscription = ""
    @Published var audioLevel: Float = 0.0
}

struct TranscriptionResult {
    let text: String
    let language: String?
    let duration: TimeInterval
}

enum WhisperError: LocalizedError {
    case modelNotFound
    case modelLoadFailed
    case transcriptionFailed
    case audioReadFailed
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Modèle Whisper non trouvé. Téléchargez-le d'abord."
        case .modelLoadFailed:
            return "Impossible de charger le modèle Whisper."
        case .transcriptionFailed:
            return "La transcription a échoué."
        case .audioReadFailed:
            return "Impossible de lire le fichier audio."
        case .downloadFailed(let message):
            return "Téléchargement échoué: \(message)"
        }
    }
}
