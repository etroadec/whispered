import Foundation
import Carbon

// MARK: - Hotkey Choice

/// Touches disponibles pour déclencher l'enregistrement
enum HotkeyChoice: String, CaseIterable, Identifiable {
    // Touches droites
    case rightCommand = "rightCommand"
    case rightOption = "rightOption"
    case rightControl = "rightControl"
    case rightShift = "rightShift"

    // Touches gauches
    case leftCommand = "leftCommand"
    case leftOption = "leftOption"
    case leftControl = "leftControl"
    case leftShift = "leftShift"

    // Touches spéciales
    case fn = "fn"
    case capsLock = "capsLock"

    // Touches de fonction
    case f1 = "f1"
    case f2 = "f2"
    case f3 = "f3"
    case f4 = "f4"
    case f5 = "f5"
    case f6 = "f6"
    case f7 = "f7"
    case f8 = "f8"
    case f9 = "f9"
    case f10 = "f10"
    case f11 = "f11"
    case f12 = "f12"

    var id: String { rawValue }

    /// Catégorie pour le regroupement dans l'UI
    var category: String {
        switch self {
        case .rightCommand, .rightOption, .rightControl, .rightShift:
            return "Touches droites"
        case .leftCommand, .leftOption, .leftControl, .leftShift:
            return "Touches gauches"
        case .fn, .capsLock:
            return "Touches spéciales"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return "Touches de fonction"
        }
    }

    /// Nom affiché dans l'interface
    var displayName: String {
        switch self {
        case .rightCommand: return "⌘ Command droit"
        case .rightOption: return "⌥ Option droit"
        case .rightControl: return "⌃ Control droit"
        case .rightShift: return "⇧ Shift droit"
        case .leftCommand: return "⌘ Command gauche"
        case .leftOption: return "⌥ Option gauche"
        case .leftControl: return "⌃ Control gauche"
        case .leftShift: return "⇧ Shift gauche"
        case .fn: return "fn Function"
        case .capsLock: return "⇪ Caps Lock"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }

    /// Symbole court de la touche
    var symbol: String {
        switch self {
        case .rightCommand, .leftCommand: return "⌘"
        case .rightOption, .leftOption: return "⌥"
        case .rightControl, .leftControl: return "⌃"
        case .rightShift, .leftShift: return "⇧"
        case .fn: return "fn"
        case .capsLock: return "⇪"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }

    /// Description complète pour le menu
    var fullDescription: String {
        switch self {
        case .rightCommand: return "⌘ droite"
        case .rightOption: return "⌥ droite"
        case .rightControl: return "⌃ droite"
        case .rightShift: return "⇧ droite"
        case .leftCommand: return "⌘ gauche"
        case .leftOption: return "⌥ gauche"
        case .leftControl: return "⌃ gauche"
        case .leftShift: return "⇧ gauche"
        case .fn: return "fn"
        case .capsLock: return "⇪ Caps Lock"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return symbol
        }
    }

    /// Keycode Carbon correspondant
    var keyCode: CGKeyCode {
        switch self {
        case .rightCommand: return 0x36  // kVK_RightCommand
        case .rightOption: return 0x3D   // kVK_RightOption
        case .rightControl: return 0x3E  // kVK_RightControl
        case .rightShift: return 0x3C    // kVK_RightShift
        case .leftCommand: return 0x37   // kVK_Command
        case .leftOption: return 0x3A    // kVK_Option
        case .leftControl: return 0x3B   // kVK_Control
        case .leftShift: return 0x38     // kVK_Shift
        case .fn: return 0x3F            // kVK_Function
        case .capsLock: return 0x39      // kVK_CapsLock
        case .f1: return 0x7A            // kVK_F1
        case .f2: return 0x78            // kVK_F2
        case .f3: return 0x63            // kVK_F3
        case .f4: return 0x76            // kVK_F4
        case .f5: return 0x60            // kVK_F5
        case .f6: return 0x61            // kVK_F6
        case .f7: return 0x62            // kVK_F7
        case .f8: return 0x64            // kVK_F8
        case .f9: return 0x65            // kVK_F9
        case .f10: return 0x6D           // kVK_F10
        case .f11: return 0x67           // kVK_F11
        case .f12: return 0x6F           // kVK_F12
        }
    }

    /// Mask CGEventFlags pour les touches modificatrices
    var flagMask: CGEventFlags? {
        switch self {
        case .rightCommand, .leftCommand: return .maskCommand
        case .rightOption, .leftOption: return .maskAlternate
        case .rightControl, .leftControl: return .maskControl
        case .rightShift, .leftShift: return .maskShift
        case .fn: return .maskSecondaryFn
        case .capsLock: return .maskAlphaShift
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return nil  // Les touches F n'ont pas de mask, on utilise keyDown/keyUp
        }
    }

    /// Indique si c'est une touche de fonction (nécessite keyDown/keyUp au lieu de flagsChanged)
    var isFunctionKey: Bool {
        switch self {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return true
        default:
            return false
        }
    }

    /// Touches groupées par catégorie pour l'affichage
    static var groupedByCategory: [(category: String, choices: [HotkeyChoice])] {
        let categories = ["Touches droites", "Touches gauches", "Touches spéciales", "Touches de fonction"]
        return categories.map { cat in
            (category: cat, choices: allCases.filter { $0.category == cat })
        }
    }
}

// MARK: - Recording Mode

/// Mode d'enregistrement
enum RecordingMode: String, CaseIterable, Identifiable {
    case hold = "hold"
    case toggle = "toggle"
    
    var id: String { rawValue }
    
    /// Nom affiche dans l'interface
    var displayName: String {
        switch self {
        case .hold: return "Maintenir"
        case .toggle: return "Appuyer"
        }
    }
    
    /// Description detaillee
    var description: String {
        switch self {
        case .hold: return "Maintenir appuye pour parler, relacher pour arreter"
        case .toggle: return "Appuyer une fois pour commencer, appuyer a nouveau pour arreter"
        }
    }
}

// MARK: - Settings Manager

/// Gestionnaire centralise des preferences de raccourcis (thread-safe)
final class HotkeySettingsManager {
    static let shared = HotkeySettingsManager()

    private let hotkeyChoiceKey = "hotkeyChoice"
    private let recordingModeKey = "recordingMode"
    private let queue = DispatchQueue(label: "com.whispered.hotkeySettings", attributes: .concurrent)

    private init() {}

    var hotkeyChoice: HotkeyChoice {
        get {
            queue.sync {
                guard let raw = UserDefaults.standard.string(forKey: hotkeyChoiceKey),
                      let choice = HotkeyChoice(rawValue: raw) else {
                    return .rightCommand
                }
                return choice
            }
        }
        set {
            queue.async(flags: .barrier) { [self] in
                UserDefaults.standard.set(newValue.rawValue, forKey: hotkeyChoiceKey)
                postNotificationOnMainThread(.hotkeySettingsDidChange)
            }
        }
    }

    var recordingMode: RecordingMode {
        get {
            queue.sync {
                guard let raw = UserDefaults.standard.string(forKey: recordingModeKey),
                      let mode = RecordingMode(rawValue: raw) else {
                    return .hold
                }
                return mode
            }
        }
        set {
            queue.async(flags: .barrier) { [self] in
                UserDefaults.standard.set(newValue.rawValue, forKey: recordingModeKey)
                postNotificationOnMainThread(.hotkeySettingsDidChange)
            }
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
    static let hotkeySettingsDidChange = Notification.Name("hotkeySettingsDidChange")
}
