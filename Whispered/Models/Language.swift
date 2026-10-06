import Foundation

// MARK: - Language Model

/// Langues disponibles pour la transcription
struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    let flag: String
    
    var id: String { code }
    
    /// Nom précédé du drapeau, pour l'affichage
    var displayName: String {
        "\(flag) \(name)"
    }
}

// MARK: - Available Languages

extension Language {
    /// Toutes les langues proposées, hors « automatique »
    static let allLanguages: [Language] = [
        Language(code: "fr", name: "Français", flag: "🇫🇷"),
        Language(code: "en", name: "Anglais", flag: "🇬🇧"),
        Language(code: "es", name: "Espagnol", flag: "🇪🇸"),
        Language(code: "de", name: "Allemand", flag: "🇩🇪"),
        Language(code: "it", name: "Italien", flag: "🇮🇹"),
        Language(code: "pt", name: "Portugais", flag: "🇵🇹"),
        Language(code: "ja", name: "Japonais", flag: "🇯🇵"),
        Language(code: "zh", name: "Chinois", flag: "🇨🇳"),
        Language(code: "nl", name: "Néerlandais", flag: "🇳🇱"),
        Language(code: "pl", name: "Polonais", flag: "🇵🇱"),
        Language(code: "ru", name: "Russe", flag: "🇷🇺"),
        Language(code: "ko", name: "Coréen", flag: "🇰🇷"),
        Language(code: "ar", name: "Arabe", flag: "🇸🇦"),
    ]
    
    /// Retrouve une langue par son code ISO
    static func byCode(_ code: String) -> Language? {
        allLanguages.first { $0.code == code }
    }
    
    /// Détection automatique par le moteur
    static let auto = Language(code: "auto", name: "Automatique", flag: "🌐")
}

// MARK: - Favorite Languages Manager

/// Langues favorites, rangées dans `UserDefaults`.
///
/// `@unchecked Sendable` : la seule donnée est dans `UserDefaults`, lui-même
/// thread-safe ; l'objet n'a aucun état propre. Pas de file de synchronisation
/// non plus — elle n'ajoutait rien et faisait bloquer le main thread à chaque
/// ouverture du menu si une écriture était en vol.
final class FavoriteLanguagesManager: @unchecked Sendable {
    static let shared = FavoriteLanguagesManager()

    private let favoritesKey = "favoriteLanguages"
    private let maxFavorites = 2

    private init() {}

    /// Langues favorites, deux au maximum
    var favorites: [String] {
        get {
                let stored = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
                return Array(stored.filter { code in
                    Language.allLanguages.contains { $0.code == code }
                }.prefix(maxFavorites))
        }
        set {
                let validCodes = newValue.filter { code in
                    Language.allLanguages.contains { $0.code == code }
                }
                let limited = Array(validCodes.prefix(maxFavorites))
                UserDefaults.standard.set(limited, forKey: favoritesKey)
                postNotificationOnMainThread(.favoriteLanguagesDidChange)
        }
    }

    /// Langues favorites sous forme d'objets Language
    var favoriteLanguages: [Language] {
        favorites.compactMap { Language.byCode($0) }
    }

    /// Ajouter une langue aux favoris
    func addFavorite(_ code: String) {
        var current = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        current = current.filter { c in Language.allLanguages.contains { $0.code == c } }

        guard !current.contains(code) else { return }
        if current.count >= maxFavorites {
            current.removeLast()
        }
        current.append(code)

        let limited = Array(current.prefix(maxFavorites))
        UserDefaults.standard.set(limited, forKey: favoritesKey)
        postNotificationOnMainThread(.favoriteLanguagesDidChange)
    }

    /// Retirer une langue des favoris
    func removeFavorite(_ code: String) {
        var current = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        current = current.filter { $0 != code }
        UserDefaults.standard.set(current, forKey: favoritesKey)
        postNotificationOnMainThread(.favoriteLanguagesDidChange)
    }

    /// Une langue est-elle dans les favoris
    func isFavorite(_ code: String) -> Bool {
        favorites.contains(code)
    }

    /// Ajoute ou retire une langue des favoris
    func toggleFavorite(_ code: String) {
        var current = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
        current = current.filter { c in Language.allLanguages.contains { $0.code == c } }

        if current.contains(code) {
            current = current.filter { $0 != code }
        } else {
            if current.count >= maxFavorites {
                current.removeLast()
            }
            current.append(code)
        }

        let limited = Array(current.prefix(maxFavorites))
        UserDefaults.standard.set(limited, forKey: favoritesKey)
        postNotificationOnMainThread(.favoriteLanguagesDidChange)
    }

    /// Poster une notification sur le main thread
    private func postNotificationOnMainThread(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let favoriteLanguagesDidChange = Notification.Name("favoriteLanguagesDidChange")
    static let selectedLanguageDidChange = Notification.Name("selectedLanguageDidChange")
}
