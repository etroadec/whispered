import Foundation
import os.log

/// Délai au-delà duquel un moteur inactif est déchargé : Parakeet et whisper
/// occupent ensemble plus d'un giga-octet de mémoire résidente.
private let engineIdleUnloadDelay: TimeInterval = 10 * 60

/// Logger hors acteur : utilisé depuis la file série de transcription.
private let transcriptionLogger = Logger(subsystem: "com.whispered", category: "Transcription")

/// Résultat d'une dictée transcrite.
struct TranscriptionOutcome: Sendable {
    let text: String
    let model: TranscriptionModel
    let language: String?
    let audioDuration: TimeInterval
    let processingTime: TimeInterval
}

/// Contextes de moteurs, détenus par la file série de `TranscriptionService`.
///
/// Ni whisper.cpp ni parakeet ne sont réentrants : cet objet n'est touché que
/// depuis cette file, jamais depuis le main actor — d'où le `@unchecked Sendable`.
private final class EngineRegistry: @unchecked Sendable {
    private var engines: [EngineKind: TranscriptionEngine] = [:]
    private var lastUsed: [EngineKind: Date] = [:]

    private static let logger = Logger(subsystem: "com.whispered", category: "Engines")

    func engine(for model: TranscriptionModel) throws -> TranscriptionEngine {
        let engine: TranscriptionEngine
        if let existing = engines[model.engine] {
            engine = existing
        } else {
            engine = model.engine == .parakeet ? ParakeetEngine() : WhisperEngine()
            engines[model.engine] = engine
        }

        if engine.loadedModel != model {
            try engine.load(model: model, at: ModelStore.path(for: model))
        }
        lastUsed[model.engine] = Date()
        return engine
    }

    /// Décharge les moteurs inactifs, sauf celui en cours d'usage.
    func unloadIdle(except active: EngineKind, olderThan delay: TimeInterval) {
        let now = Date()
        for (kind, date) in lastUsed where kind != active {
            guard now.timeIntervalSince(date) > delay, let engine = engines[kind] else { continue }
            engine.unload()
            engines.removeValue(forKey: kind)
            lastUsed.removeValue(forKey: kind)
            Self.logger.info("Moteur \(kind.displayName, privacy: .public) déchargé (inactif)")
        }
    }

    func unloadAll() {
        for engine in engines.values {
            engine.unload()
        }
        engines.removeAll()
        lastUsed.removeAll()
    }
}

/// Point d'entrée unique de la transcription : choisit le moteur, garde les
/// contextes chargés, sérialise les appels.
@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var currentModel: TranscriptionModel
    /// Vrai dès qu'au moins une transcription est en cours. Un compteur et non
    /// un booléen : avec deux dictées concurrentes, le `defer` de la première
    /// remettait le drapeau à faux alors que la seconde tournait encore.
    var isTranscribing: Bool { runningTranscriptions > 0 }
    @Published private(set) var runningTranscriptions = 0
    /// Modèle en cours de chargement, pour l'affichage
    @Published private(set) var loadingModel: TranscriptionModel?

    private let queue = DispatchQueue(label: "com.whispered.transcription", qos: .userInitiated)
    private let registry = EngineRegistry()
    private var idleTimer: Timer?

    private static let logger = Logger(subsystem: "com.whispered", category: "Transcription")
    private static let modelKey = "selectedModel"
    /// Version du catalogue appliquée, pour que la migration ne se rejoue pas
    private static let migrationKey = "modelCatalogMigrationVersion"
    private static let currentCatalogVersion = 2

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.modelKey) ?? TranscriptionModel.default.rawValue

        if defaults.integer(forKey: Self.migrationKey) < Self.currentCatalogVersion {
            let migrated = TranscriptionModel.migrated(from: stored)
            currentModel = migrated
            defaults.set(migrated.rawValue, forKey: Self.modelKey)
            defaults.set(Self.currentCatalogVersion, forKey: Self.migrationKey)
            if migrated.rawValue != stored {
                Self.logger.notice("Modèle migré : \(stored, privacy: .public) → \(migrated.rawValue, privacy: .public)")
            }
        } else {
            currentModel = TranscriptionModel(rawValue: stored) ?? .default
        }
        startIdleTimer()
    }

    // MARK: - Modèle actif

    /// Modèle de l'autre moteur, s'il est installé : c'est lui que déclenche le
    /// second raccourci en mode « autre moteur ».
    var alternateModel: TranscriptionModel? {
        TranscriptionModel.allCases.first {
            $0.engine != currentModel.engine && ModelStore.isInstalled($0)
        }
    }

    var isReady: Bool {
        ModelStore.isInstalled(currentModel)
    }

    func select(model: TranscriptionModel) {
        guard model != currentModel else { return }
        currentModel = model
        UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey)
        Self.logger.info("Modèle actif : \(model.rawValue, privacy: .public)")
        preload(model)
    }

    /// Charge un modèle d'avance, pour que la première dictée ne paie pas les
    /// 150 à 500 ms de lecture du fichier.
    func preload(_ model: TranscriptionModel? = nil) {
        let target = model ?? currentModel
        guard ModelStore.isInstalled(target) else { return }
        loadingModel = target
        queue.async { [registry] in
            do {
                _ = try registry.engine(for: target)
            } catch {
                // Un modèle corrompu doit se voir ici, pas à la première dictée
                transcriptionLogger.error("Préchargement de \(target.rawValue, privacy: .public) échoué : \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor [weak self] in
                guard let self, self.loadingModel == target else { return }
                self.loadingModel = nil
            }
        }
    }

    // MARK: - Transcription

    /// Transcrit des échantillons PCM float 16 kHz mono.
    /// - Parameters:
    ///   - model: forcer un modèle (second raccourci), sinon le modèle actif.
    ///   - language: code ISO, ignoré par Parakeet qui détecte seul.
    func transcribe(
        samples: [Float],
        using model: TranscriptionModel? = nil,
        language: String? = nil,
        translateToEnglish: Bool = false
    ) async throws -> TranscriptionOutcome {
        let target = model ?? currentModel
        guard ModelStore.isInstalled(target) else {
            throw TranscriptionError.modelNotInstalled(target)
        }

        let audioDuration = Double(samples.count) / 16000.0
        let requestedLanguage = target.supportsLanguageSelection ? language : nil
        let translate = target.supportsTranslation && translateToEnglish

        runningTranscriptions += 1
        defer { runningTranscriptions -= 1 }

        let started = Date()
        let registry = self.registry

        let rawText: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    // Le VAD écarte le silence avant de réveiller le moteur, et
                    // rogne les blancs : whisper encode toujours 30 s, autant
                    // qu'elles contiennent de la parole.
                    let analysis = VoiceActivityDetector.shared.analyze(samples: samples)
                    guard analysis.hasSpeech, let range = analysis.range else {
                        continuation.resume(throwing: TranscriptionError.noSpeechDetected)
                        return
                    }
                    let trimmed = range.count == samples.count ? samples : Array(samples[range])

                    let engine = try registry.engine(for: target)
                    let text = try engine.transcribe(
                        samples: trimmed,
                        language: requestedLanguage,
                        translateToEnglish: translate
                    )
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        // Le nettoyeur distingue « rien dit » d'une boucle de décodage : sans
        // ça, une transcription partie en boucle était annoncée à l'utilisateur
        // comme « Aucune parole détectée ».
        let sanitized = TranscriptionSanitizer.sanitize(rawText)
        guard sanitized.isAccepted else {
            throw TranscriptionError.rejected(sanitized.rejection ?? .empty)
        }

        return TranscriptionOutcome(
            text: sanitized.text,
            model: target,
            language: requestedLanguage,
            audioDuration: audioDuration,
            processingTime: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Entretien

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let active = self.currentModel.engine
                self.queue.async { [registry = self.registry] in
                    registry.unloadIdle(except: active, olderThan: engineIdleUnloadDelay)
                }
            }
        }
    }

    func cleanup() {
        idleTimer?.invalidate()
        idleTimer = nil
        // Le VAD se libère sur la même file que `analyze` : un
        // `whisper_vad_free` depuis le main thread pendant une analyse en cours
        // est un use-after-free.
        queue.sync { [registry] in
            registry.unloadAll()
            VoiceActivityDetector.shared.unload()
        }
    }
}
