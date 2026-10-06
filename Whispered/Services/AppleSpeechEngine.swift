import AVFoundation
import Foundation
import Speech
import os.log

/// Session de dictée en direct, vue par l'app sans dépendre de macOS 26.
@MainActor
protocol LiveDictationSession: AnyObject, Sendable {
    /// Format exact attendu par le moteur : aucune conversion implicite
    var audioFormat: AVAudioFormat { get }
    /// Appelé depuis le thread audio, d'où le `nonisolated`
    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer)
    func finishSession() async -> String
    func cancelSession() async
}

/// Moteur de transcription du système, introduit par macOS 26 (`SpeechAnalyzer`
/// / `SpeechTranscriber`).
///
/// Son intérêt n'est pas la précision : mesuré sur la même phrase française,
/// il laisse tomber les virgules et le point d'interrogation que Parakeet
/// restitue, et il écrit « pool request » et « repos JO » là où Parakeet écrit
/// « pull request ». Son intérêt est ailleurs : **zéro modèle à télécharger**
/// (les voix sont fournies par le système) et un premier mot disponible 26 ms
/// après le début de la parole, ce qui permet d'afficher le texte pendant la
/// dictée.
///
/// Trois limites à connaître :
/// - macOS 26 minimum, Apple Silicon uniquement ;
/// - une locale fixée à l'initialisation, **aucune détection de langue** ;
/// - `AnalysisContext.contextualStrings` n'a aucun effet mesurable sur ce
///   module (vérifié : sortie identique au caractère près), donc pas de
///   vocabulaire métier — c'est le dictionnaire de corrections de l'app qui
///   joue ce rôle.
@available(macOS 26.0, *)
final class AppleSpeechEngine: Sendable {
    static let shared = AppleSpeechEngine()

    private static let logger = Logger(subsystem: "com.whispered", category: "AppleSpeech")

    private init() {}

    /// Le matériel sait faire tourner le moteur (faux sur Intel).
    static var isSupported: Bool {
        SpeechTranscriber.isAvailable
    }

    /// Locales dont le modèle est déjà installé sur la machine.
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// Normalise un code de langue de l'app (« fr », « en »…) en locale acceptée.
    /// L'égalité de `Locale` dépend de la façon dont il a été créé : il faut
    /// passer par `supportedLocale(equivalentTo:)` et non comparer des chaînes.
    static func resolveLocale(for languageCode: String) async -> Locale? {
        let candidates: [String]
        if languageCode == "auto" {
            // Pas de détection de langue : on prend la langue du système, puis le français
            candidates = [Locale.current.identifier, "fr-FR"]
        } else if languageCode.contains("-") {
            candidates = [languageCode]
        } else {
            // « fr » seul ne matche pas : on tente les variantes courantes
            candidates = ["\(languageCode)-\(languageCode.uppercased())",
                          "\(languageCode)-FR", "\(languageCode)-US", languageCode]
        }

        for candidate in candidates {
            if let resolved = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: candidate)
            ) {
                return resolved
            }
        }
        return nil
    }

    /// Format audio attendu, à connaître avant de démarrer l'enregistrement.
    static func preferredAudioFormat(for languageCode: String) async -> AVAudioFormat? {
        guard isSupported, let locale = await resolveLocale(for: languageCode) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    /// Télécharge le modèle de langue si le système ne l'a pas déjà.
    static func installAssetsIfNeeded(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Self.logger.info("Téléchargement du modèle système pour \(locale.identifier(.bcp47), privacy: .public)")
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Dictée en direct

    /// Session de dictée : les résultats arrivent au fil de la parole.
    ///
    /// `onPartial` reçoit le texte en cours de construction (à afficher), et la
    /// valeur de retour de `finish()` est le texte définitif.
    @MainActor
    final class LiveSession {
        private let transcriber: SpeechTranscriber
        private let analyzer: SpeechAnalyzer
        private let continuation: AsyncStream<AnalyzerInput>.Continuation
        private let analysisTask: Task<Void, Never>
        private let collectorTask: Task<String, Never>

        /// Format exact attendu par le module : aucune conversion implicite sur
        /// le chemin « flux de buffers ».
        let inputFormat: AVAudioFormat

        init(locale: Locale, onPartial: @escaping @MainActor (String) -> Void) async throws {
            transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            ) else {
                throw TranscriptionError.engineFailed("format audio incompatible")
            }
            inputFormat = format

            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            self.continuation = continuation

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            // Préchauffe le moteur : sans cela le premier résultat arrive une
            // seconde plus tard.
            try await analyzer.prepareToAnalyze(in: format)

            // La finalisation arrive par blocs de 20 à 30 s : attendre `isFinal`
            // ne donnerait rien sur une dictée courte. On compose donc le texte
            // finalisé et le fragment volatil en cours.
            let results = transcriber.results
            collectorTask = Task { @MainActor in
                var finalized = ""
                do {
                    for try await result in results {
                        if result.isFinal {
                            finalized += String(result.text.characters)
                            onPartial(finalized)
                        } else {
                            onPartial(finalized + String(result.text.characters))
                        }
                    }
                } catch {
                    AppleSpeechEngine.logger.error("Flux de résultats interrompu : \(error.localizedDescription, privacy: .public)")
                }
                return finalized
            }

            analysisTask = Task {
                _ = try? await analyzer.analyzeSequence(stream)
            }
        }

        /// Pousse un buffer déjà converti au format `inputFormat`.
        /// Appelé depuis le thread audio : la continuation est `Sendable`, donc
        /// pas besoin de repasser par le main actor pour chaque bloc.
        nonisolated func append(_ buffer: AVAudioPCMBuffer) {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }

        /// Termine la session et rend le texte complet.
        /// Terminer le flux ne suffit pas à clore l'analyse : il faut appeler
        /// une méthode `finalizeAndFinish*`, sinon le flux de résultats ne se
        /// termine jamais.
        /// Termine la session et rend le texte complet, sans attendre
        /// indéfiniment : si le flux de résultats ne se termine pas, la dictée
        /// resterait bloquée sur « Transcription… ».
        func finish() async -> String {
            continuation.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()

            let collector = collectorTask
            let analysis = analysisTask
            return await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    _ = await analysis.value
                    return await collector.value
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                if first == nil {
                    AppleSpeechEngine.logger.notice("Finalisation du direct abandonnée après 2 s")
                }
                return first ?? ""
            }
        }

        func cancel() async {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            analysisTask.cancel()
            collectorTask.cancel()
        }
    }

    /// Ouvre une session de dictée en direct pour la langue demandée.
    @MainActor
    func startLiveSession(
        languageCode: String,
        onPartial: @escaping @MainActor (String) -> Void
    ) async throws -> LiveSession {
        guard Self.isSupported else {
            throw TranscriptionError.engineFailed("moteur système indisponible sur ce Mac")
        }
        guard let locale = await Self.resolveLocale(for: languageCode) else {
            throw TranscriptionError.engineFailed("langue non prise en charge par le moteur système")
        }
        try await Self.installAssetsIfNeeded(for: locale)
        return try await LiveSession(locale: locale, onPartial: onPartial)
    }
}

// MARK: - Conformance au protocole non versionné

@available(macOS 26.0, *)
extension AppleSpeechEngine.LiveSession: LiveDictationSession {
    var audioFormat: AVAudioFormat { inputFormat }

    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        append(buffer)
    }

    func finishSession() async -> String {
        await finish()
    }

    func cancelSession() async {
        await cancel()
    }
}
