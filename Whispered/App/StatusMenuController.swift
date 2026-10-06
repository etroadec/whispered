import AppKit

/// Élément de menu qui porte son action, pour éviter une forêt de sélecteurs
/// `@objc` et des `representedObject` à décoder.
///
/// `target = self` ne crée pas de cycle : AppKit déclare `target` en `weak`.
/// L'item reste vivant assez longtemps pour délivrer son action, son menu le
/// retenant pendant tout l'affichage.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(
        title: String,
        symbol: String? = nil,
        keyEquivalent: String = "",
        checked: Bool = false,
        enabled: Bool = true,
        handler: @escaping @MainActor () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: keyEquivalent)
        self.target = self
        self.action = #selector(fire)
        self.isEnabled = enabled
        self.state = checked ? .on : .off
        if let symbol {
            image = Self.symbolImage(symbol)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("non supporté : ces items sont construits en code")
    }

    @objc private func fire() {
        handler()
    }

    /// Les symboles sont partagés : le menu est reconstruit à chaque ouverture.
    private static var symbolCache: [String: NSImage] = [:]

    static func symbolImage(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(scale: .small))
        symbolCache[name] = image
        return image
    }
}

/// Construit le menu de la barre des menus.
///
/// Le menu est rempli à chaque ouverture depuis un `State` explicite, et les
/// actions sont des fermetures : la structure est donc vérifiable sans lancer
/// l'application ni cliquer.
///
/// Le niveau supérieur ne garde que les actions ; les réglages passent en
/// sous-menu, dont le titre porte la valeur courante — convention macOS pour un
/// choix exclusif, qui évite d'ouvrir trois sous-menus pour savoir où on en est.
@MainActor
final class StatusMenuController {

    // MARK: - Ce que le menu affiche

    struct Download: Equatable {
        let model: TranscriptionModel
        let fraction: Double
    }

    struct State {
        /// Modèle choisi dans les préférences, téléchargé ou non
        var selectedModel: TranscriptionModel
        /// Son fichier est présent et exploitable
        var isModelInstalled: Bool
        var installedModels: [TranscriptionModel]
        /// Le moteur du système peut prendre le relais sans modèle téléchargé
        var canDictateWithoutModel: Bool

        var isRecording: Bool
        var isTranscribing: Bool
        var download: Download?
        var missingAccessibility: Bool
        var missingMicrophone: Bool
        /// Dernière dictée, nil s'il n'y en a pas
        var lastDictation: String?
        var language: String
        var favoriteLanguages: [Language]
        var insertionMode: InsertionMode
        var hotkeyDescription: String

        /// Modèle réellement actif, nil si le fichier manque
        var activeModel: TranscriptionModel? { isModelInstalled ? selectedModel : nil }

        /// Dicter est possible : soit le modèle est là, soit le moteur système
        /// prend le relais. La version précédente grisait « Dicter » au premier
        /// lancement alors que le raccourci, lui, fonctionnait.
        var canDictate: Bool { isModelInstalled || canDictateWithoutModel }
    }

    // MARK: - Ce que le menu déclenche

    struct Actions {
        var dictate: @MainActor () -> Void = {}
        var stopDictation: @MainActor () -> Void = {}
        var repeatLast: @MainActor () -> Void = {}
        var openHistory: @MainActor () -> Void = {}
        var openSettings: @MainActor (SettingsView.Tab) -> Void = { _ in }
        var selectModel: @MainActor (TranscriptionModel) -> Void = { _ in }
        var selectLanguage: @MainActor (String) -> Void = { _ in }
        var selectInsertionMode: @MainActor (InsertionMode) -> Void = { _ in }
        var openAccessibilitySettings: @MainActor () -> Void = {}
        var openMicrophoneSettings: @MainActor () -> Void = {}
        var quit: @MainActor () -> Void = {}
    }

    private let actions: Actions

    /// L'item de progression, pour rafraîchir son intitulé menu ouvert :
    /// reconstruire le menu entier déplacerait la sélection de l'utilisateur.
    private weak var downloadItem: NSMenuItem?

    init(actions: Actions) {
        self.actions = actions
    }

    // MARK: - Construction

    /// Remplit un menu existant. Le menu reste attaché au `NSStatusItem`, ce
    /// qui donne l'ouverture au mouse-down, le clic droit et la navigation
    /// clavier des extras — tout ce qu'un menu posé juste avant un
    /// `performClick` simulé ne donne pas.
    func populate(_ menu: NSMenu, state: State) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        downloadItem = nil

        addHeader(to: menu, state: state)
        addAttentionItems(to: menu, state: state)
        addActions(to: menu, state: state)

        menu.addItem(.separator())
        addSubmenus(to: menu, state: state)

        menu.addItem(.separator())
        addFooter(to: menu)
    }

    /// Pour les vérifications hors application.
    func makeMenu(state: State) -> NSMenu {
        let menu = NSMenu()
        populate(menu, state: state)
        return menu
    }

    /// Met à jour le seul pourcentage de téléchargement, menu ouvert.
    func refreshDownload(_ download: Download?) {
        guard let item = downloadItem else { return }
        item.title = download.map(Self.downloadTitle) ?? "Téléchargement terminé"
    }

    var isShowingDownload: Bool { downloadItem != nil }

    // MARK: - En-tête

    private func addHeader(to menu: NSMenu, state: State) {
        let title: String
        if state.isRecording {
            title = "À l'écoute…"
        } else if state.isTranscribing {
            title = "Transcription…"
        } else if let model = state.activeModel {
            title = model.displayName
        } else {
            title = "Aucun modèle installé"
        }
        // Vrai en-tête de section, et non un item désactivé que le curseur survole.
        menu.addItem(.sectionHeader(title: title))
    }

    /// Ce qui empêche l'app de fonctionner, et seulement ça : rien ne s'affiche
    /// ici quand tout va bien.
    private func addAttentionItems(to menu: NSMenu, state: State) {
        var added = false

        if state.missingAccessibility {
            menu.addItem(ActionMenuItem(
                title: "Autoriser l'accessibilité…",
                symbol: "exclamationmark.triangle.fill",
                handler: actions.openAccessibilitySettings
            ))
            added = true
        }
        if state.missingMicrophone {
            menu.addItem(ActionMenuItem(
                title: "Autoriser le microphone…",
                symbol: "exclamationmark.triangle.fill",
                handler: actions.openMicrophoneSettings
            ))
            added = true
        }

        if let download = state.download {
            let item = NSMenuItem(title: Self.downloadTitle(download), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = ActionMenuItem.symbolImage("arrow.down.circle")
            menu.addItem(item)
            downloadItem = item
            added = true
        } else if !state.isModelInstalled {
            let openSettings = actions.openSettings
            menu.addItem(ActionMenuItem(
                title: "Télécharger un modèle…",
                symbol: "arrow.down.circle",
                handler: { openSettings(.engine) }
            ))
            added = true
        }

        if added {
            menu.addItem(.separator())
        }
    }

    private static func downloadTitle(_ download: Download) -> String {
        let percent = Int((download.fraction * 100).rounded())
        return "Téléchargement de \(download.model.displayName) : \(percent) %"
    }

    // MARK: - Actions

    private func addActions(to menu: NSMenu, state: State) {
        if state.isRecording {
            menu.addItem(ActionMenuItem(
                title: "Arrêter la dictée",
                handler: actions.stopDictation
            ))
        } else {
            // Le raccourci figure dans l'intitulé et non comme équivalent
            // clavier : ⌘ droite n'en est pas un.
            menu.addItem(ActionMenuItem(
                title: "Dicter  (\(state.hotkeyDescription))",
                enabled: state.canDictate,
                handler: actions.dictate
            ))
        }

        if let last = state.lastDictation {
            menu.addItem(ActionMenuItem(
                title: "Réinsérer « \(Self.shortened(last)) »",
                handler: actions.repeatLast
            ))
        }

        menu.addItem(ActionMenuItem(
            title: "Historique…",
            handler: actions.openHistory
        ))
    }

    // MARK: - Sous-menus

    private func addSubmenus(to menu: NSMenu, state: State) {
        let engineValue = state.isModelInstalled
            ? state.selectedModel.displayName
            : "\(state.selectedModel.displayName), absent"
        menu.addItem(submenuItem(
            title: "Moteur : \(engineValue)",
            submenu: engineSubmenu(state: state)
        ))

        menu.addItem(submenuItem(
            title: "Langue : \(Self.languageLabel(state))",
            submenu: languageSubmenu(state: state)
        ))

        menu.addItem(submenuItem(
            title: "Insertion : \(state.insertionMode.displayName.lowercased())",
            submenu: insertionSubmenu(state: state)
        ))
    }

    private static func languageLabel(_ state: State) -> String {
        guard state.selectedModel.supportsLanguageSelection else { return "automatique" }
        if state.language == "auto" { return "automatique" }
        return Language.byCode(state.language)?.name ?? state.language
    }

    private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Changer de moteur sans passer par les préférences : c'est le réglage le
    /// plus souvent touché, selon qu'on dicte une phrase courte ou du jargon.
    private func engineSubmenu(state: State) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let select = actions.selectModel

        for model in TranscriptionModel.allCases {
            let installed = state.installedModels.contains(model)
            let title = installed
                ? model.displayName
                : "\(model.displayName) — \(model.formattedSize) à télécharger"
            submenu.addItem(ActionMenuItem(
                title: title,
                checked: state.selectedModel == model,
                // Changer de moteur en pleine dictée ferait transcrire par
                // l'autre moteur l'audio déjà capturé.
                enabled: installed && !state.isRecording,
                handler: { select(model) }
            ))
        }

        if state.isRecording {
            let note = NSMenuItem(
                title: "Changement impossible pendant la dictée",
                action: nil,
                keyEquivalent: ""
            )
            note.isEnabled = false
            submenu.addItem(.separator())
            submenu.addItem(note)
        }

        let openSettings = actions.openSettings
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem(
            title: "Gérer les modèles…",
            handler: { openSettings(.engine) }
        ))
        return submenu
    }

    /// Parakeet reconnaît la langue tout seul : plutôt qu'un choix sans effet,
    /// le sous-menu explique pourquoi il est inactif.
    ///
    /// Le test porte sur le modèle **choisi** et non sur le modèle installé :
    /// avec Whisper sélectionné mais pas encore téléchargé, la langue choisie
    /// s'appliquera bien à la prochaine dictée.
    private func languageSubmenu(state: State) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let select = actions.selectLanguage
        let openSettings = actions.openSettings

        guard state.selectedModel.supportsLanguageSelection else {
            let explanation = NSMenuItem(
                title: "Reconnue automatiquement par \(state.selectedModel.engine.displayName)",
                action: nil,
                keyEquivalent: ""
            )
            explanation.isEnabled = false
            submenu.addItem(explanation)
            submenu.addItem(.separator())
            submenu.addItem(ActionMenuItem(
                title: "Choisir une langue avec Whisper…",
                handler: { openSettings(.engine) }
            ))
            return submenu
        }

        submenu.addItem(ActionMenuItem(
            title: Language.auto.displayName,
            checked: state.language == "auto",
            handler: { select("auto") }
        ))

        if !state.favoriteLanguages.isEmpty {
            submenu.addItem(.separator())
            for language in state.favoriteLanguages {
                submenu.addItem(ActionMenuItem(
                    title: language.displayName,
                    checked: state.language == language.code,
                    handler: { select(language.code) }
                ))
            }
        }

        // La langue active n'est ni « auto » ni un favori : on l'affiche quand
        // même, sinon rien n'est coché et le menu paraît faux.
        if state.language != "auto",
           !state.favoriteLanguages.contains(where: { $0.code == state.language }),
           let current = Language.byCode(state.language) {
            submenu.addItem(.separator())
            submenu.addItem(ActionMenuItem(
                title: current.displayName,
                checked: true,
                handler: { select(current.code) }
            ))
        }

        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem(
            title: "Toutes les langues…",
            handler: { openSettings(.general) }
        ))
        return submenu
    }

    private func insertionSubmenu(state: State) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let select = actions.selectInsertionMode
        for mode in InsertionMode.allCases {
            submenu.addItem(ActionMenuItem(
                title: mode.displayName,
                checked: state.insertionMode == mode,
                handler: { select(mode) }
            ))
        }
        return submenu
    }

    // MARK: - Pied

    private func addFooter(to menu: NSMenu) {
        let openSettings = actions.openSettings
        // Pas d'équivalent clavier affiché sur Préférences ni Historique :
        // l'app est un extra de la barre des menus, sans menu principal, donc
        // un ⌘, ne fonctionnerait que le menu ouvert. Autant ne rien promettre.
        menu.addItem(ActionMenuItem(
            title: "Préférences…",
            handler: { openSettings(.general) }
        ))
        menu.addItem(ActionMenuItem(
            title: "Quitter Whispered",
            keyEquivalent: "q",
            handler: actions.quit
        ))
    }

    // MARK: - Utilitaires

    /// Un aperçu de dictée ne doit pas piloter la largeur du menu : 30
    /// caractères. La version précédente en affichait jusqu'à 80.
    static func shortened(_ text: String, limit: Int = 30) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}
