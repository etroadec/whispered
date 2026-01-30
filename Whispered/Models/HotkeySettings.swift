import Foundation
import Carbon

// MARK: - Hotkey Choice

/// Touches disponibles pour declencher l'enregistrement
enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightCommand = "rightCommand"
    case fn = "fn"
    case rightOption = "rightOption"
    case rightControl = "rightControl"
    
    var id: String { rawValue }
    
    /// Nom affiche dans l'interface
    var displayName: String {
        switch self {
        case .rightCommand: return "Command droit"
        case .fn: return "Fn (Function)"
        case .rightOption: return "Option droit"
        case .rightControl: return "Control droit"
        }
    }
    
    /// Symbole de la touche pour l'affichage
    var symbol: String {
        switch self {
        case .rightCommand: return "⌘"
        case .fn: return "fn"
        case .rightOption: return "⌥"
        case .rightControl: return "⌃"
        }
    }
    
    /// Description complete avec symbole
    var fullDescription: String {
        switch self {
        case .rightCommand: return "⌘ droite"
        case .fn: return "fn"
        case .rightOption: return "⌥ droite"
        case .rightControl: return "⌃ droite"
        }
    }
    
    /// Keycode Carbon correspondant
    var keyCode: CGKeyCode {
        switch self {
        case .rightCommand: return 0x36  // kVK_RightCommand
        case .fn: return 0x3F            // kVK_Function
        case .rightOption: return 0x3D   // kVK_RightOption
        case .rightControl: return 0x3E  // kVK_RightControl
        }
    }
    
    /// Mask CGEventFlags a verifier pour detecter si la touche est pressee
    /// Note: La touche Fn n'a pas de mask standard dans CGEventFlags
    var flagMask: CGEventFlags? {
        switch self {
        case .rightCommand: return .maskCommand
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
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
