import Foundation

/// Les deux moteurs de transcription embarqués.
enum EngineKind: String, Codable {
    case parakeet
    case whisper

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        }
    }
}

/// Modèles proposés par l'app.
///
/// Le catalogue est volontairement court. Mesuré sur un M5 avec un extrait de
/// français de 3 s : Parakeet rend le texte en 50 ms, whisper large-v3-turbo en
/// 710 ms — et whisper paie ce coût à l'identique pour 3 s ou 12 s d'audio,
/// puisqu'il complète toujours une fenêtre de 30 s. Les modèles tiny, base,
/// small, medium et large-v3 ont été retirés : tous dominés en qualité comme en
/// vitesse par l'un des deux restants.
enum TranscriptionModel: String, CaseIterable, Identifiable {
    case parakeetV3Q8 = "parakeet-tdt-0.6b-v3-q8_0"
    case parakeetV3Q4 = "parakeet-tdt-0.6b-v3-q4_k"
    case whisperTurboQ5 = "large-v3-turbo-q5_0"

    var id: String { rawValue }

    static let `default`: TranscriptionModel = .parakeetV3Q8

    var engine: EngineKind {
        switch self {
        case .parakeetV3Q8, .parakeetV3Q4: return .parakeet
        case .whisperTurboQ5: return .whisper
        }
    }

    var displayName: String {
        switch self {
        case .parakeetV3Q8: return "Parakeet v3"
        case .parakeetV3Q4: return "Parakeet v3 (léger)"
        case .whisperTurboQ5: return "Whisper large-v3-turbo"
        }
    }

    var detail: String {
        switch self {
        case .parakeetV3Q8:
            return "Le plus rapide et le plus précis en français. 25 langues européennes, détection automatique."
        case .parakeetV3Q4:
            return "Même vitesse, 240 Mo de moins, qualité très proche."
        case .whisperTurboQ5:
            return "99 langues et traduction vers l'anglais. Plus lent, meilleur sur le jargon anglais."
        }
    }

    /// Taille exacte du fichier publié, relevée par requête HTTP.
    /// Exacte et non arrondie : c'est elle qui sert à repérer un téléchargement
    /// interrompu ou une page d'erreur enregistrée sous le nom du modèle.
    var expectedBytes: Int64 {
        switch self {
        case .parakeetV3Q8: return 668_757_119
        case .parakeetV3Q4: return 415_611_879
        case .whisperTurboQ5: return 574_041_195
        }
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: expectedBytes)
    }

    var fileName: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL {
        switch engine {
        case .parakeet:
            return URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/\(fileName)")!
        case .whisper:
            return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
        }
    }

    /// Parakeet détecte la langue tout seul et n'accepte aucun paramètre de langue.
    var supportsLanguageSelection: Bool {
        engine == .whisper
    }

    var supportsTranslation: Bool {
        engine == .whisper
    }

    /// Licence à citer dans l'app
    var licence: String {
        switch engine {
        case .parakeet: return "NVIDIA Parakeet TDT 0.6B v3, CC-BY-4.0"
        case .whisper: return "OpenAI Whisper via whisper.cpp, MIT"
        }
    }

    // MARK: - Migration

    /// Fait correspondre les anciennes valeurs enregistrées au nouveau catalogue.
    ///
    /// Le routage n'est pas uniforme, et c'est volontaire : qui avait choisi
    /// `tiny`, `base` ou `small` l'avait fait **pour la vitesse**. L'envoyer sur
    /// whisper large-v3-turbo lui imposerait le plus lent des deux moteurs et
    /// 547 Mo de téléchargement ; Parakeet est à la fois plus rapide et plus
    /// précis que ces trois modèles. Les gros modèles, eux, étaient choisis pour
    /// la qualité et les langues : ils restent sur whisper.
    static func migrated(from storedValue: String) -> TranscriptionModel {
        let target = mapped(from: storedValue)

        // Vaut aussi pour une valeur déjà au format v2 : si son fichier a été
        // supprimé alors que l'autre modèle est là, autant partir de celui-là
        // plutôt que d'afficher « aucun modèle installé ».
        if !ModelStore.isInstalled(target),
           let installed = TranscriptionModel.allCases.first(where: { ModelStore.isInstalled($0) }) {
            return installed
        }
        return target
    }

    private static func mapped(from storedValue: String) -> TranscriptionModel {
        if let exact = TranscriptionModel(rawValue: storedValue) {
            return exact
        }

        switch storedValue {
        case "tiny", "base", "small",
             "tiny.en", "base.en", "small.en":
            return .parakeetV3Q8
        case "medium", "medium.en", "large", "large-v1", "large-v2",
             "large-v3", "large-v3-q5_0", "large-v3-turbo":
            return .whisperTurboQ5
        default:
            return .default
        }
    }

    /// Modèles retirés du catalogue dont le fichier peut encore traîner sur le disque.
    static let retiredFileNames: [String] = [
        "ggml-tiny.bin",
        "ggml-base.bin",
        "ggml-small.bin",
        "ggml-medium.bin",
        "ggml-large-v3.bin",
        "ggml-large-v3-q5_0.bin",
        "ggml-large-v3-turbo.bin",
    ]
}

/// Erreurs communes aux deux moteurs.
enum TranscriptionError: LocalizedError {
    case modelNotInstalled(TranscriptionModel)
    case modelLoadFailed(TranscriptionModel)
    case engineFailed(String)
    case noSpeechDetected
    /// Texte produit mais écarté, avec la raison exacte
    case rejected(TranscriptionSanitizer.Rejection)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let model):
            return "Le modèle \(model.displayName) n'est pas téléchargé."
        case .modelLoadFailed(let model):
            return "Chargement de \(model.displayName) impossible."
        case .engineFailed(let detail):
            return "La transcription a échoué : \(detail)"
        case .noSpeechDetected:
            return "Aucune parole détectée"
        case .rejected(let reason):
            return reason.userMessage
        case .cancelled:
            return "Transcription annulée"
        }
    }
}

/// Un moteur sait charger un modèle et transcrire des échantillons 16 kHz mono.
///
/// Les implémentations ne sont pas thread-safe : ni whisper.cpp ni parakeet ne
/// le sont. Tous les appels passent par la file série de `TranscriptionService`.
protocol TranscriptionEngine: AnyObject {
    var kind: EngineKind { get }
    var loadedModel: TranscriptionModel? { get }

    /// Charge le modèle, ou le remplace si un autre était chargé.
    func load(model: TranscriptionModel, at path: URL) throws

    /// Transcrit des échantillons PCM float 16 kHz mono.
    /// - Parameters:
    ///   - language: code ISO, ou nil pour laisser le moteur décider.
    ///   - translateToEnglish: ignoré par les moteurs qui ne traduisent pas.
    func transcribe(samples: [Float], language: String?, translateToEnglish: Bool) throws -> String

    func unload()
}
