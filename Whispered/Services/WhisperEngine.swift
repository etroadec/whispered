import Foundation
import WhisperCpp
import os.log

/// Moteur whisper.cpp, conservé pour ce que Parakeet ne sait pas faire :
/// les langues hors Europe, la traduction vers l'anglais, et un second avis
/// quand Parakeet se trompe.
final class WhisperEngine: TranscriptionEngine {
    let kind: EngineKind = .whisper

    private(set) var loadedModel: TranscriptionModel?
    private var context: OpaquePointer?

    /// La chaîne C passée à whisper doit rester valide pendant tout l'appel.
    /// `(String as NSString).utf8String` renvoie un pointeur interne à un objet
    /// temporaire, et `withUnsafeBufferPointer` ne garantit rien au-delà de sa
    /// fermeture : on possède donc explicitement la mémoire.
    private var languagePointer: UnsafeMutablePointer<CChar>?

    private static let logger = Logger(subsystem: "com.whispered", category: "WhisperEngine")

    // MARK: - Chargement

    func load(model: TranscriptionModel, at path: URL) throws {
        unload()

        var params = whisper_context_default_params()
        params.use_gpu = true
        // Gain net sur Apple Silicon depuis whisper.cpp 1.7
        params.flash_attn = true

        guard let ctx = whisper_init_from_file_with_params(path.path, params) else {
            Self.logger.error("Chargement de \(model.fileName, privacy: .public) échoué")
            throw TranscriptionError.modelLoadFailed(model)
        }

        context = ctx
        loadedModel = model
        Self.logger.info("Modèle chargé : \(model.fileName, privacy: .public)")
    }

    func unload() {
        guard let ctx = context else { return }
        whisper_free(ctx)
        context = nil
        loadedModel = nil
        freeLanguagePointer()
    }

    private func freeLanguagePointer() {
        if let languagePointer {
            free(languagePointer)
        }
        languagePointer = nil
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], language: String?, translateToEnglish: Bool) throws -> String {
        guard let ctx = context else {
            throw TranscriptionError.engineFailed("aucun modèle chargé")
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.translate = translateToEnglish
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_context = true
        params.n_threads = Int32(Self.threadCount)

        // Garde-fous contre les hallucinations à la source, en plus du VAD :
        // les jetons de non-parole ne sont même pas générés.
        params.suppress_nst = true
        params.suppress_blank = true
        params.no_speech_thold = 0.6
        params.entropy_thold = 2.4
        params.logprob_thold = -1.0
        params.temperature_inc = 0.2

        freeLanguagePointer()
        if let language, language != "auto" {
            languagePointer = strdup(language)
            params.language = UnsafePointer(languagePointer)
        } else {
            params.language = nil
        }

        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(samples.count))
        }

        guard result == 0 else {
            throw TranscriptionError.engineFailed("whisper_full a retourné \(result)")
        }

        var text = ""
        for index in 0..<whisper_full_n_segments(ctx) {
            if let segment = whisper_full_get_segment_text(ctx, index) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nombre de threads de calcul. `activeProcessorCount` compte les cœurs
    /// d'efficacité, qui ralentissent le calcul au lieu de l'accélérer, et le
    /// nombre de cœurs d'efficacité varie selon la puce (2 sur M1 Pro, 4 sur M1).
    static var threadCount: Int {
        let total = ProcessInfo.processInfo.activeProcessorCount
        // Les deux tiers des cœurs, bornés : approximation raisonnable du nombre
        // de cœurs de performance sur toutes les puces Apple.
        return max(2, min((total * 2) / 3, 8))
    }

    deinit {
        if let ctx = context {
            whisper_free(ctx)
        }
        if let languagePointer {
            free(languagePointer)
        }
    }
}
