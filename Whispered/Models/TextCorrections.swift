import Foundation
import os.log

/// Une règle de correction appliquée au texte transcrit.
///
/// Aucun moteur de transcription n'écrit correctement les noms propres et le
/// jargon dictés à la française : mesuré sur la même phrase, Parakeet rend
/// « repos J-Hub », whisper « repos JHub » et le moteur d'Apple « repos JO »
/// là où il faut lire « repo GitHub ». Une table de remplacement règle ces cas
/// de façon déterministe, ce que le vocabulaire contextuel d'Apple ne fait pas.
struct CorrectionRule: Codable, Identifiable, Equatable {
    let id: UUID
    /// Texte ou motif à chercher
    var pattern: String
    /// Texte de remplacement
    var replacement: String
    /// Traiter `pattern` comme une expression régulière
    var isRegex: Bool
    /// Ignorer la casse. Les accents, eux, comptent : « cafe » ne corrige pas
    /// « café ». Pour couvrir les deux, écris une règle par forme, ou une
    /// expression régulière.
    var ignoresCase: Bool
    /// Ne remplacer que des mots entiers (ignoré en mode expression régulière)
    var wholeWordsOnly: Bool
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String,
        isRegex: Bool = false,
        ignoresCase: Bool = true,
        wholeWordsOnly: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.ignoresCase = ignoresCase
        self.wholeWordsOnly = wholeWordsOnly
        self.isEnabled = isEnabled
    }

    /// Motif effectif, échappé et éventuellement borné sur les limites de mot
    fileprivate var effectivePattern: String {
        if isRegex { return pattern }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        guard wholeWordsOnly else { return escaped }
        // \b ne fonctionne pas devant un caractère non alphanumérique : on borne
        // seulement les extrémités qui en sont une.
        let prefix = pattern.first.map { isWordCharacter($0) ? "\\b" : "" } ?? ""
        let suffix = pattern.last.map { isWordCharacter($0) ? "\\b" : "" } ?? ""
        return prefix + escaped + suffix
    }

    private func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Message d'erreur si le motif est invalide, nil s'il compile
    var validationError: String? {
        guard !pattern.isEmpty else { return "Le motif est vide." }
        do {
            _ = try NSRegularExpression(pattern: effectivePattern, options: [])
            return nil
        } catch {
            return "Expression régulière invalide : \(error.localizedDescription)"
        }
    }
}

/// Table de corrections appliquée après transcription, quel que soit le moteur.
@MainActor
final class TextCorrections: ObservableObject {
    static let shared = TextCorrections()

    @Published var rules: [CorrectionRule] {
        didSet {
            save()
            rebuildCache()
        }
    }

    /// Appliquer les corrections (désactivable globalement)
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let rulesKey = "correctionRules"
    private static let enabledKey = "correctionsEnabled"
    private static let logger = Logger(subsystem: "com.whispered", category: "Corrections")

    /// Expressions compilées une fois, et non à chaque dictée
    private var compiled: [(regex: NSRegularExpression, replacement: String)] = []

    /// Quelques règles pour démarrer, tirées des erreurs réellement observées
    static let defaultRules: [CorrectionRule] = [
        // Erreurs relevées en mesurant les trois moteurs sur la même phrase
        CorrectionRule(pattern: "pool request", replacement: "pull request"),
        CorrectionRule(pattern: "repos J-Hub", replacement: "repo GitHub"),
        CorrectionRule(pattern: "repos JHub", replacement: "repo GitHub"),
        CorrectionRule(pattern: "repos JO", replacement: "repo GitHub"),
        CorrectionRule(pattern: "git hub", replacement: "GitHub"),
        CorrectionRule(pattern: "supa base", replacement: "Supabase"),
        CorrectionRule(pattern: "clod code", replacement: "Claude Code"),
    ]

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        if let data = UserDefaults.standard.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([CorrectionRule].self, from: data) {
            rules = decoded
        } else {
            rules = Self.defaultRules
        }
        rebuildCache()
    }

    // MARK: - Application

    /// Applique les règles actives dans l'ordre de la liste.
    func apply(to text: String) -> String {
        guard isEnabled, !compiled.isEmpty, !text.isEmpty else { return text }
        var result = text
        for item in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = item.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: item.replacement
            )
        }
        return result
    }

    // MARK: - Édition

    func add(_ rule: CorrectionRule) {
        rules.append(rule)
    }

    func update(_ rule: CorrectionRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
    }

    func remove(_ rule: CorrectionRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func resetToDefaults() {
        rules = Self.defaultRules
    }

    // MARK: - Interne

    private func rebuildCache() {
        compiled = rules.compactMap { rule in
            guard rule.isEnabled else { return nil }
            var options: NSRegularExpression.Options = []
            if rule.ignoresCase {
                options.insert(.caseInsensitive)
            }
            // Fait coller `\b` aux limites de mot Unicode, pour que « café »
            // soit bien un mot entier. Cette option ne touche pas aux accents.
            options.insert(.useUnicodeWordBoundaries)
            do {
                let regex = try NSRegularExpression(pattern: rule.effectivePattern, options: options)
                // En mode littéral, le remplacement ne doit pas interpréter $1, \1…
                let template = rule.isRegex
                    ? rule.replacement
                    : NSRegularExpression.escapedTemplate(for: rule.replacement)
                return (regex, template)
            } catch {
                Self.logger.error("Règle ignorée (motif invalide): \(rule.pattern, privacy: .public)")
                return nil
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.rulesKey)
    }
}
