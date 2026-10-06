import AppKit
import ApplicationServices
import Carbon
import Foundation
import os.log

/// Façon dont le texte transcrit rejoint l'application active.
enum InsertionMode: String, CaseIterable, Identifiable {
    /// Insertion dans le champ actif (accessibilité, puis presse-papier en repli)
    case direct
    /// Rien n'est inséré : le texte est seulement copié
    case clipboardOnly
    /// Insertion précédée d'une espace, pour enchaîner sur la dictée précédente
    case append

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "Insérer"
        case .clipboardOnly: return "Copier seulement"
        case .append: return "Ajouter à la suite"
        }
    }

    var detail: String {
        switch self {
        case .direct: return "Le texte est inséré dans le champ actif."
        case .clipboardOnly: return "Le texte va dans le presse-papier, à toi de le coller."
        case .append: return "Comme Insérer, mais précédé d'une espace."
        }
    }
}

/// Résultat d'une tentative d'insertion, pour que l'interface dise la vérité
/// au lieu d'annoncer « Transcrit ! » quand rien n'a été inséré.
enum InjectionOutcome {
    /// Texte écrit directement dans le champ via l'API d'accessibilité
    case insertedViaAccessibility
    /// Texte collé avec ⌘V
    case pasted
    /// Texte uniquement disponible dans le presse-papier
    case copiedOnly(reason: CopyOnlyReason)

    enum CopyOnlyReason {
        /// Mode « copier seulement » demandé dans les préférences
        case userPreference
        /// Saisie sécurisée active : macOS bloque les événements clavier simulés
        case secureInputActive
        /// Aucune méthode d'insertion n'a fonctionné
        case insertionFailed

        var message: String {
            switch self {
            case .userPreference: return "Copié dans le presse-papier"
            case .secureInputActive: return "Saisie sécurisée : copié, à coller avec ⌘V"
            case .insertionFailed: return "Insertion impossible : copié dans le presse-papier"
            }
        }
    }

    var message: String {
        switch self {
        case .insertedViaAccessibility, .pasted: return "Transcrit !"
        case .copiedOnly(let reason): return reason.message
        }
    }
}

/// Sans état mutable : seules des constantes statiques.
final class TextInjector: Sendable {
    static let shared = TextInjector()

    private static let logger = Logger(subsystem: "com.whispered", category: "TextInjector")

    /// Délai laissé au système pour traiter le ⌘V avant de restaurer le presse-papier
    private static let pasteboardRestoreDelay: TimeInterval = 0.6

    /// Temps maximum accordé à une requête d'accessibilité : au-delà, on passe
    /// au presse-papier plutôt que de geler la dictée sur une app qui ne répond pas.
    private static let axTimeout: Float = 0.3

    private init() {}

    // MARK: - Point d'entrée

    @discardableResult
    func inject(_ text: String, mode: InsertionMode = .direct) -> InjectionOutcome {
        guard !text.isEmpty else { return .copiedOnly(reason: .insertionFailed) }

        let payload = (mode == .append) ? " " + text : text

        if mode == .clipboardOnly {
            copyToClipboard(payload)
            return .copiedOnly(reason: .userPreference)
        }

        // La saisie sécurisée (champ de mot de passe, certains terminaux) fait
        // ignorer les CGEvent : inutile d'essayer, on le dit à l'utilisateur.
        if IsSecureEventInputEnabled() {
            Self.logger.notice("Saisie sécurisée active, insertion impossible")
            copyToClipboard(payload)
            return .copiedOnly(reason: .secureInputActive)
        }

        if insertViaAccessibility(payload) {
            return .insertedViaAccessibility
        }

        if pasteViaClipboard(payload) {
            return .pasted
        }

        copyToClipboard(payload)
        return .copiedOnly(reason: .insertionFailed)
    }

    // MARK: - Méthode 1 : accessibilité

    /// Écrit le texte dans le champ actif sans toucher au presse-papier.
    /// Fonctionne dans les apps natives ; échoue dans la plupart des apps web et
    /// des terminaux, d'où le repli.
    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axTimeout)

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        // La valeur vient du serveur d'accessibilité d'un autre processus : on
        // vérifie son type réel avant de la convertir, plutôt que de faire
        // confiance et de tomber sur un force-cast.
        guard status == .success, let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Self.logger.debug("Élément focalisé indisponible")
            return false
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, Self.axTimeout)

        // Un champ non modifiable refusera l'écriture : on vérifie avant d'essayer,
        // sinon certaines apps insèrent le texte dans un champ en lecture seule.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if result == .success {
            Self.logger.debug("Insertion via accessibilité réussie")
            return true
        }
        return false
    }

    // MARK: - Méthode 2 : presse-papier + ⌘V

    private func pasteViaClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general

        // Sauvegarde complète : types ET données, pour ne pas perdre une image
        // ou un fichier qui se trouvait dans le presse-papier.
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        guard simulatePaste() else {
            return false
        }

        // Restauration différée, et seulement si personne d'autre n'a écrit
        // entre-temps.
        //
        // Quand le presse-papier était vide au départ, le texte dicté y reste
        // volontairement : rien ne garantit que l'application cible a traité le
        // ⌘V, et dans ce cas c'est le seul moyen de récupérer la dictée à la
        // main. Il n'y a rien à restaurer par-dessus.
        guard let saved, !saved.isEmpty else { return true }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelay) {
            guard pasteboard.changeCount == changeCountAfterWrite else {
                Self.logger.debug("Presse-papier modifié par ailleurs, restauration annulée")
                return
            }
            pasteboard.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(items)
        }
        return true
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Simule ⌘V.
    ///
    /// Retourne false seulement si les événements n'ont pas pu être créés : rien
    /// ne permet de savoir si l'application cible a réellement traité le
    /// collage. Dans une app qui ignore ⌘V, le texte reste dans le
    /// presse-papier — d'où la restauration différée, qui laisse le temps de le
    /// coller à la main.
    private func simulatePaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            Self.logger.error("Création des événements clavier impossible")
            return false
        }

        // Neutralise les modificateurs encore enfoncés : le raccourci de dictée est
        // souvent une touche morte (⌘ droite) relâchée juste avant cet appel, et un
        // ⌘⇧V ou ⌥⌘V involontaire déclencherait autre chose qu'un collage.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
