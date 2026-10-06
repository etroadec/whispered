import Foundation
import WhisperCpp
import os.log

/// Moteur Parakeet TDT v3, via la bibliothèque `libparakeet` de whisper.cpp
/// (support ajouté en v1.9.0, juin 2026).
///
/// Deux différences notables avec whisper :
/// le coût de l'encodeur est proportionnel à la durée de l'audio au lieu d'être
/// fixé sur une fenêtre de 30 s, et le décodeur transducteur peut ne rien
/// produire — sur cinq secondes de silence il rend une chaîne vide, là où
/// whisper rend « ... » ou une phrase inventée.
final class ParakeetEngine: TranscriptionEngine {
    let kind: EngineKind = .parakeet

    private(set) var loadedModel: TranscriptionModel?
    private var context: OpaquePointer?

    private static let logger = Logger(subsystem: "com.whispered", category: "ParakeetEngine")

    // MARK: - Chargement

    func load(model: TranscriptionModel, at path: URL) throws {
        unload()

        var params = parakeet_context_default_params()
        params.use_gpu = true

        guard let ctx = parakeet_init_from_file_with_params(path.path, params) else {
            Self.logger.error("Chargement de \(model.fileName, privacy: .public) échoué")
            throw TranscriptionError.modelLoadFailed(model)
        }

        context = ctx
        loadedModel = model
        Self.logger.info("Modèle chargé : \(model.fileName, privacy: .public)")
    }

    func unload() {
        guard let ctx = context else { return }
        parakeet_free(ctx)
        context = nil
        loadedModel = nil
    }

    // MARK: - Transcription

    /// `language` et `translateToEnglish` sont ignorés : Parakeet v3 détecte la
    /// langue parmi 25 langues européennes, n'expose aucun paramètre de langue
    /// et ne traduit pas.
    func transcribe(samples: [Float], language: String?, translateToEnglish: Bool) throws -> String {
        guard let ctx = context else {
            throw TranscriptionError.engineFailed("aucun modèle chargé")
        }

        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.threadCount)
        // Chaque dictée est indépendante : pas de contexte hérité de la précédente,
        // qui ferait dériver la transcription d'une phrase sur l'autre.
        params.no_context = true

        let result = samples.withUnsafeBufferPointer { buffer in
            parakeet_full(ctx, params, buffer.baseAddress, Int32(samples.count))
        }

        guard result == 0 else {
            throw TranscriptionError.engineFailed("parakeet_full a retourné \(result)")
        }

        var text = ""
        for index in 0..<parakeet_full_n_segments(ctx) {
            if let segment = parakeet_full_get_segment_text(ctx, index) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Même règle que pour whisper : éviter les cœurs d'efficacité sans
    /// supposer combien la puce en compte.
    static var threadCount: Int { WhisperEngine.threadCount }

    deinit {
        if let ctx = context {
            parakeet_free(ctx)
        }
    }
}
