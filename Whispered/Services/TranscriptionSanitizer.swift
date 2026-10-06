import Foundation
import os.log

/// Nettoyage du texte brut rendu par un moteur.
///
/// Remplace la liste noire de phrases qui vivait dans `AppDelegate` : elle jetait
/// des dictées parfaitement légitimes (« merci beaucoup », « au revoir »,
/// « thank you ») et, avec son `trimmed.count < 3`, tout ce qui faisait moins de
/// trois caractères — « ok », « va », « si », « 42 ».
///
/// Trois filtres, aucun basé sur le sens des mots :
/// 1. **marqueurs de non-parole** — `[BLANK_AUDIO]`, `[MUSIC]`, `♪` : des jetons
///    émis par le modèle, jamais des mots prononcés ;
/// 2. **boucle de décodage** — un même n-gramme répété anormalement, symptôme
///    classique des transducteurs RNN-T comme Parakeet (whisper.cpp #4088) et
///    des décodeurs auto-régressifs ;
/// 3. **vide** après nettoyage.
///
/// Sans état, donc utilisable depuis n'importe quel thread.
enum TranscriptionSanitizer {
    private static let logger = Logger(subsystem: "com.whispered", category: "Sanitizer")

    // MARK: - Résultat

    enum Rejection: String {
        /// Le moteur n'a rien produit.
        case empty
        /// Uniquement des marqueurs de non-parole.
        case markersOnly
        /// Boucle de décodage : le texte n'était qu'une répétition.
        case degenerateLoop

        var userMessage: String {
            switch self {
            case .empty, .markersOnly: return "Aucune parole détectée"
            case .degenerateLoop:      return "Transcription incohérente, ignorée"
            }
        }
    }

    struct Result {
        let text: String
        let rejection: Rejection?
        /// Vrai si une répétition a été réduite sans que le texte soit rejeté.
        let didCollapseRepetition: Bool

        var isAccepted: Bool { rejection == nil && !text.isEmpty }
    }

    // MARK: - Réglages

    /// Longueur maximale du n-gramme recherché, en mots.
    private static let maxNGramLength = 5

    /// Seuil de répétitions consécutives au-delà duquel un n-gramme est une boucle.
    /// Un mot seul répété trois fois est courant et légitime en français
    /// (« non non non », « très très bien ») : on ne coupe qu'à partir de quatre.
    private static func repetitionLimit(forNGramLength n: Int) -> Int {
        n == 1 ? 4 : 3
    }

    /// En dessous, pas de détection de boucle : trop de faux positifs sur un texte court.
    private static let minimumWordsForLoopDetection = 4

    /// Contenus de parenthèses qui désignent de la non-parole. Les crochets, eux,
    /// sont toujours retirés : aucun moteur n'émet `[...]` pour du texte prononcé,
    /// alors qu'un utilisateur peut dicter « (voir annexe) ».
    /// Passées par `normalizedKey`, qui retire aussi les espaces : sans cette
    /// normalisation, « no speech » et « pas de parole » ne pouvaient jamais
    /// correspondre, puisque la clé comparée valait « nospeech ».
    private static let nonSpeechParentheticals: Set<String> = Set([
        "blank audio", "music", "musique", "applause", "applaudissements",
        "laughter", "rires", "rire", "silence", "inaudible", "no speech", "pas de parole",
        "bruit", "noise", "sons", "sound", "soupir", "sighs", "toux", "cough",
    ].map(normalizedKey))

    private static let bracketRegex = try? NSRegularExpression(pattern: #"\[[^\]]*\]"#)
    private static let parentheticalRegex = try? NSRegularExpression(pattern: #"\(([^\)]*)\)"#)
    private static let musicSymbols = CharacterSet(charactersIn: "\u{266a}\u{266b}\u{266c}\u{2669}")

    // MARK: - API

    /// Version courte : le texte nettoyé, ou une chaîne vide si rejeté.
    /// Correspond à l'usage dans `TranscriptionService`.
    static func clean(_ raw: String) -> String {
        sanitize(raw).text
    }

    /// Version complète, avec la raison du rejet pour que l'interface dise la vérité.
    static func sanitize(_ raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(text: "", rejection: .empty, didCollapseRepetition: false)
        }

        // 1. Marqueurs de non-parole.
        let withoutMarkers = stripNonSpeechMarkers(trimmed)
        guard !withoutMarkers.isEmpty else {
            logger.info("Rejeté : marqueurs de non-parole uniquement")
            return Result(text: "", rejection: .markersOnly, didCollapseRepetition: false)
        }

        // 2. Boucle de décodage.
        let charCollapsed = collapseCharacterRuns(withoutMarkers)
        let (collapsed, didCollapse) = collapseRepeatedNGrams(charCollapsed)

        let originalWords = wordCount(withoutMarkers)
        let collapsedWords = wordCount(collapsed)

        // Un texte long qui se réduit à un ou deux mots n'était qu'une boucle.
        if didCollapse, originalWords >= 8, collapsedWords <= 2 {
            logger.notice("Rejeté : boucle de décodage (\(originalWords) mots → \(collapsedWords))")
            return Result(text: "", rejection: .degenerateLoop, didCollapseRepetition: true)
        }

        let normalized = normalizeWhitespace(collapsed)
        guard !normalized.isEmpty else {
            return Result(text: "", rejection: .empty, didCollapseRepetition: didCollapse)
        }

        if didCollapse {
            logger.notice("Répétition réduite : \(originalWords) → \(collapsedWords) mots")
        }

        return Result(text: normalized, rejection: nil, didCollapseRepetition: didCollapse)
    }

    // MARK: - Marqueurs

    private static func stripNonSpeechMarkers(_ text: String) -> String {
        var working = text

        if let regex = bracketRegex {
            working = regex.stringByReplacingMatches(
                in: working,
                range: NSRange(working.startIndex..., in: working),
                withTemplate: " "
            )
        }

        if let regex = parentheticalRegex {
            let matches = regex.matches(in: working, range: NSRange(working.startIndex..., in: working))
            // À l'envers : remplacer par la fin garde les index valides.
            for match in matches.reversed() {
                guard match.numberOfRanges == 2,
                      let fullRange = Range(match.range(at: 0), in: working),
                      let innerRange = Range(match.range(at: 1), in: working) else { continue }
                if nonSpeechParentheticals.contains(normalizedKey(String(working[innerRange]))) {
                    working.replaceSubrange(fullRange, with: " ")
                }
            }
        }

        working = String(String.UnicodeScalarView(working.unicodeScalars.filter { !musicSymbols.contains($0) }))

        // S'il ne reste que de la ponctuation, c'était un marqueur.
        let hasContent = working.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        guard hasContent else { return "" }

        return normalizeWhitespace(working)
    }

    // MARK: - Répétitions

    /// Réduit toute suite de quatre caractères identiques ou plus à trois :
    /// « aaaaaaa » → « aaa », « !!!!!!!! » → « !!! ». Attrape les boucles
    /// sub-lexicales sans toucher à un mot réel (aucun mot français n'a trois
    /// fois la même lettre d'affilée).
    private static func collapseCharacterRuns(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.count)

        var previous: Character?
        var runLength = 0

        for character in text {
            if character == previous {
                runLength += 1
            } else {
                previous = character
                runLength = 1
            }
            if runLength <= 3 { output.append(character) }
        }
        return output
    }

    /// Réduit les n-grammes répétés consécutivement à une seule occurrence.
    /// Balayage glouton de gauche à droite, n-grammes les plus courts d'abord :
    /// « le chat le chat le chat dort » → « le chat dort ».
    private static func collapseRepeatedNGrams(_ text: String) -> (text: String, didCollapse: Bool) {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= minimumWordsForLoopDetection else { return (text, false) }

        let keys = words.map { normalizedKey(String($0)) }

        var output: [Substring] = []
        output.reserveCapacity(words.count)

        var didCollapse = false
        var index = 0

        while index < words.count {
            var collapsedHere = false
            let maxN = min(maxNGramLength, (words.count - index) / 2)

            if maxN >= 1 {
                // Du plus court au plus long : une suite du MÊME mot doit être
                // vue comme un unigramme répété, pas comme un bigramme répété
                // (« oui oui oui oui oui oui » → « oui », et non « oui oui »).
                for n in 1...maxN {
                    let pattern = Array(keys[index..<(index + n)])
                    var repeats = 1
                    var cursor = index + n

                    while cursor + n <= words.count, keys[cursor..<(cursor + n)].elementsEqual(pattern) {
                        repeats += 1
                        cursor += n
                    }

                    if repeats >= repetitionLimit(forNGramLength: n) {
                        // Une seule occurrence conservée : au-delà du seuil, ce
                        // n'est plus une insistance mais une boucle de
                        // décodage, et en garder plusieurs empêcherait de la
                        // reconnaître comme telle.
                        output.append(contentsOf: words[index..<(index + n)])
                        index += repeats * n
                        didCollapse = true
                        collapsedHere = true
                        break
                    }
                }
            }

            if !collapsedHere {
                output.append(words[index])
                index += 1
            }
        }

        return (output.joined(separator: " "), didCollapse)
    }

    // MARK: - Normalisation

    /// Clé de comparaison : minuscules, sans diacritiques, sans ponctuation.
    /// Si le mot n'est que de la ponctuation, on garde sa forme repliée pour que
    /// deux signes différents ne soient pas confondus.
    static func normalizedKey(_ word: String) -> String {
        let folded = word
            .lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
        let stripped = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let key = String(String.UnicodeScalarView(stripped))
        return key.isEmpty ? folded : key
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
