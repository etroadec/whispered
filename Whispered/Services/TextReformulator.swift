import Foundation
import FoundationModels
import os.log

/// Style de réécriture appliqué à une dictée.
enum ReformulationStyle: String, CaseIterable, Identifiable {
    /// Ponctuation, majuscules, hésitations retirées, rien d'autre
    case clean
    /// Passe du parlé à l'écrit, phrases complètes
    case written
    /// Traduit en anglais
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clean: return "Nettoyer"
        case .written: return "Passer à l'écrit"
        case .english: return "Traduire en anglais"
        }
    }

    var detail: String {
        switch self {
        case .clean: return "Ponctuation et majuscules rétablies, hésitations retirées. Les mots restent les tiens."
        case .written: return "Transforme le parlé en phrases écrites, sans changer le fond."
        case .english: return "Traduit la dictée en anglais."
        }
    }

    var instructions: String {
        switch self {
        case .clean:
            return """
            Tu corriges des transcriptions de dictée vocale en français.
            Rétablis la ponctuation, les majuscules et les accents. Supprime les hésitations
            (« euh », « bah », répétitions involontaires). Ne reformule pas, ne résume pas,
            n'ajoute rien, ne traduis pas, ne commente pas.
            Réponds uniquement par le texte corrigé.
            """
        case .written:
            return """
            Tu transformes une dictée vocale française en texte écrit.
            Phrases complètes et ponctuées, tournures parlées remplacées par leur équivalent écrit,
            hésitations supprimées. Garde le sens, le ton et les informations à l'identique :
            tu ne résumes pas et tu n'ajoutes rien.
            Réponds uniquement par le texte réécrit.
            """
        case .english:
            return """
            You translate French dictation into natural English.
            Keep the meaning, tone and all information. Fix punctuation and capitalisation.
            Do not summarise, do not add anything, do not comment.
            Reply with the translation only.
            """
        }
    }
}

/// Réécriture de la dictée par le modèle de langue embarqué dans macOS 26.
///
/// Gratuit, hors ligne, mais conditionné à Apple Intelligence : sur une machine
/// où il n'est pas activé, `availability` renvoie `appleIntelligenceNotEnabled`
/// et l'app doit le dire plutôt que d'échouer en silence.
@available(macOS 26.0, *)
enum TextReformulator {
    private static let logger = Logger(subsystem: "com.whispered", category: "Reformulator")

    /// Au-delà, on n'attend pas : la dictée est rendue telle quelle.
    private static let timeout: TimeInterval = 8

    enum Availability: Equatable {
        case ready
        /// Apple Intelligence n'est pas activé dans les Réglages Système
        case appleIntelligenceDisabled
        /// Modèle en cours de téléchargement par le système
        case downloading
        case unsupportedDevice
        case unavailable(String)

        var isReady: Bool { self == .ready }

        var message: String {
            switch self {
            case .ready:
                return "Prêt."
            case .appleIntelligenceDisabled:
                return "Active Apple Intelligence dans Réglages Système pour utiliser la réécriture."
            case .downloading:
                return "Le modèle de langue est en cours de téléchargement par le système."
            case .unsupportedDevice:
                return "Ce Mac ne prend pas en charge le modèle de langue d'Apple."
            case .unavailable(let detail):
                return "Modèle de langue indisponible : \(detail)"
            }
        }
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceDisabled
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable(.deviceNotEligible):
            return .unsupportedDevice
        case .unavailable(let reason):
            return .unavailable(String(describing: reason))
        @unknown default:
            return .unavailable("raison inconnue")
        }
    }

    /// Réécrit le texte, ou le rend inchangé si le modèle n'est pas disponible
    /// ou met trop de temps : une dictée ne doit jamais être perdue parce que la
    /// réécriture a échoué.
    static func reformulate(_ text: String, style: ReformulationStyle) async -> String {
        guard availability.isReady, !text.isEmpty else { return text }

        let started = Date()
        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: style.instructions)
                    let response = try await session.respond(to: text)
                    return response.content
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CancellationError()
                }
                let first = try await group.next()
                group.cancelAll()
                return first ?? text
            }

            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return text }

            logger.info("Réécriture en \(Date().timeIntervalSince(started), privacy: .public) s")
            return cleaned
        } catch is CancellationError {
            logger.notice("Réécriture abandonnée après \(Int(timeout), privacy: .public) s")
            return text
        } catch {
            logger.error("Réécriture échouée : \(error.localizedDescription, privacy: .public)")
            return text
        }
    }
}
