import Foundation

// MARK: - Language Model

/// Langues supportees par Whisper pour la transcription
struct Language: Identifiable, Hashable {
    let code: String
    let name: String
    let flag: String
    
    var id: String { code }
    
    /// Nom avec emoji drapeau pour l'affichage
    var displayName: String {
        "\(flag) \(name)"
    }
}

// MARK: - Available Languages

extension Language {
    /// Toutes les langues disponibles (hors "auto")
    static let allLanguages: [Language] = [
        Language(code: "fr", name: "Francais", flag: "🇫🇷"),
        Language(code: "en", name: "Anglais", flag: "🇬🇧"),
        Language(code: "es", name: "Espagnol", flag: "🇪🇸"),
        Language(code: "de", name: "Allemand", flag: "🇩🇪"),
        Language(code: "it", name: "Italien", flag: "🇮🇹"),
        Language(code: "pt", name: "Portugais", flag: "🇵🇹"),
        Language(code: "ja", name: "Japonais", flag: "🇯🇵"),
        Language(code: "zh", name: "Chinois", flag: "🇨🇳"),
        Language(code: "nl", name: "Neerlandais", flag: "🇳🇱"),
        Language(code: "pl", name: "Polonais", flag: "🇵🇱"),
        Language(code: "ru", name: "Russe", flag: "🇷🇺"),
        Language(code: "ko", name: "Coreen", flag: "🇰🇷"),
        Language(code: "ar", name: "Arabe", flag: "🇸🇦"),
    ]
    
    /// Trouver une langue par son code
    static func byCode(_ code: String) -> Language? {
        allLanguages.first { $0.code == code }
    }
    
    /// Option "Automatique" speciale
    static let auto = Language(code: "auto", name: "Automatique", flag: "🌐")
}

// MARK: - Favorite Languages Manager

/// Gestionnaire des langues favorites (thread-safe)
final class FavoriteLanguagesManager {
    static let shared = FavoriteLanguagesManager()

    private let favoritesKey = "favoriteLanguages"
    private let maxFavorites = 2
    private let queue = DispatchQueue(label: "com.whispered.favorites", attributes: .concurrent)

    private init() {}

    /// Langues favorites (max 2) - thread-safe
    var favorites: [String] {
        get {
            queue.sync {
                let stored = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
                return Array(stored.filter { code in
                    Language.allLanguages.contains { $0.code == code }
                }.prefix(maxFavorites))
            }
        }
        set {
            queue.async(flags: .barrier) { [self] in
                let validCodes = newValue.filter { code in
                    Language.allLanguages.contains { $0.code == code }
                }
                let limited = Array(validCodes.prefix(maxFavorites))
                UserDefaults.standard.set(limited, forKey: favoritesKey)
                postNotificationOnMainThread(.favoriteLanguagesDidChange)
            }
        }
    }

    /// Langues favorites sous forme d'objets Language
    var favoriteLanguages: [Language] {
        favorites.compactMap { Language.byCode($0) }
    }

    /// Ajouter une langue aux favoris - thread-safe
    func addFavorite(_ code: String) {
        queue.async(flags: .barrier) { [self] in
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
    }

    /// Retirer une langue des favoris - thread-safe
    func removeFavorite(_ code: String) {
        queue.async(flags: .barrier) { [self] in
            var current = UserDefaults.standard.stringArray(forKey: favoritesKey) ?? []
            current = current.filter { $0 != code }
            UserDefaults.standard.set(current, forKey: favoritesKey)
            postNotificationOnMainThread(.favoriteLanguagesDidChange)
        }
    }

    /// Verifier si une langue est favorite
    func isFavorite(_ code: String) -> Bool {
        favorites.contains(code)
    }

    /// Toggle une langue dans les favoris
    func toggleFavorite(_ code: String) {
        queue.async(flags: .barrier) { [self] in
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
