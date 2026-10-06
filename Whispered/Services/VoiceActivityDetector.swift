import Foundation
import WhisperCpp
import os.log

/// Détection de parole par le modèle Silero livré avec whisper.cpp.
///
/// **Confinement** : `analyze` et `unload` ne doivent être appelés que depuis la
/// file série de `TranscriptionService`. Le contexte n'est protégé par aucun
/// verrou : le libérer depuis un autre thread pendant une analyse plante.
///
/// Remplace le seuil RMS global de la version précédente (0,005 sur l'énergie
/// moyenne du fichier), qui coupait une phrase murmurée et laissait passer un
/// ventilateur. Le VAD sert à trois choses : ne pas transcrire quand il n'y a
/// pas de parole, rogner les blancs avant et après — ce qui accélère whisper —
/// et, en mode « appuyer », arrêter l'enregistrement sur un silence.
/// `@unchecked Sendable` assumé : l'objet n'est touché que depuis la file série
/// de `TranscriptionService`, jamais en parallèle. Le compilateur ne peut pas le
/// vérifier, le confinement est documenté juste au-dessus.
final class VoiceActivityDetector: @unchecked Sendable {
    static let shared = VoiceActivityDetector()

    /// Modèle Silero v5.1.2, 0,8 Mo
    static let modelFileName = "ggml-silero-v5.1.2.bin"
    static let modelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(modelFileName)")!

    private var context: OpaquePointer?
    /// Mémorise un échec de chargement : sans ça, chaque dictée relit le fichier
    /// sur le disque et log la même erreur.
    private var loadFailed = false
    private static let logger = Logger(subsystem: "com.whispered", category: "VAD")

    /// Repli quand le modèle n'est pas installé : seuil d'énergie, comme avant.
    private static let fallbackRMSThreshold: Float = 0.005

    private init() {}

    var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.modelPath.path)
    }

    static var modelPath: URL {
        ModelStore.modelsDirectory.appendingPathComponent(modelFileName)
    }

    // MARK: - Analyse

    struct Analysis {
        /// Vrai si au moins un segment de parole a été trouvé
        let hasSpeech: Bool
        /// Bornes de parole en nombre d'échantillons, marges incluses
        let range: Range<Int>?
    }

    /// Analyse des échantillons 16 kHz mono.
    /// À n'appeler que depuis la file série de `TranscriptionService`.
    func analyze(samples: [Float]) -> Analysis {
        guard !samples.isEmpty else {
            return Analysis(hasSpeech: false, range: nil)
        }

        guard let ctx = loadedContext() else {
            let hasSpeech = rms(of: samples) >= Self.fallbackRMSThreshold
            return Analysis(hasSpeech: hasSpeech, range: hasSpeech ? 0..<samples.count : nil)
        }

        var params = whisper_vad_default_params()
        // Marge généreuse : mieux vaut transcrire 200 ms de silence que
        // couper la première syllabe d'un mot.
        params.speech_pad_ms = 200
        params.min_speech_duration_ms = 120
        params.min_silence_duration_ms = 300

        guard let segments = samples.withUnsafeBufferPointer({ buffer in
            whisper_vad_segments_from_samples(ctx, params, buffer.baseAddress, Int32(samples.count))
        }) else {
            Self.logger.error("Analyse VAD échouée, repli sur le seuil d'énergie")
            let hasSpeech = rms(of: samples) >= Self.fallbackRMSThreshold
            return Analysis(hasSpeech: hasSpeech, range: hasSpeech ? 0..<samples.count : nil)
        }
        defer { whisper_vad_free_segments(segments) }

        let count = whisper_vad_segments_n_segments(segments)
        guard count > 0 else {
            return Analysis(hasSpeech: false, range: nil)
        }

        // Les bornes sont en centisecondes, marges `speech_pad_ms` incluses.
        // On ajoute 100 ms de chaque côté : une syllabe coupée coûte plus
        // cher que 1 600 échantillons de silence transcrits.
        let safety = 1_600
        let firstStart = whisper_vad_segments_get_segment_t0(segments, 0)
        let lastEnd = whisper_vad_segments_get_segment_t1(segments, count - 1)

        let start = max(0, Int((Double(firstStart) / 100 * 16000).rounded()) - safety)
        let end = min(samples.count, Int((Double(lastEnd) / 100 * 16000).rounded()) + safety)

        guard start < end else {
            return Analysis(hasSpeech: true, range: 0..<samples.count)
        }
        return Analysis(hasSpeech: true, range: start..<end)
    }

    // MARK: - Interne

    private func loadedContext() -> OpaquePointer? {
        if let context { return context }
        guard !loadFailed, isModelInstalled else { return nil }

        var params = whisper_vad_default_context_params()
        // Réseau de 0,9 Mo : monter un graphe Metal coûte plus que le calcul,
        // et entrerait en concurrence avec la file Metal du moteur principal.
        params.use_gpu = false
        params.n_threads = 2

        guard let ctx = whisper_vad_init_from_file_with_params(Self.modelPath.path, params) else {
            Self.logger.error("Chargement du modèle VAD impossible, repli sur le seuil d'énergie")
            loadFailed = true
            return nil
        }
        context = ctx
        Self.logger.info("Modèle VAD chargé")
        return ctx
    }

    private func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// À n'appeler que depuis la file série de `TranscriptionService`.
    func unload() {
        if let context {
            whisper_vad_free(context)
        }
        context = nil
        loadFailed = false
    }

    deinit {
        if let context {
            whisper_vad_free(context)
        }
    }
}
