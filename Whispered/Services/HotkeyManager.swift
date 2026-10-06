import Carbon
import Cocoa
import Foundation
import os.log

/// Lequel des deux raccourcis a été actionné.
enum HotkeyRole {
    case primary
    case secondary
}

/// Surveille les touches de déclenchement via un tap CGEvent.
///
/// Deux raccourcis peuvent être suivis en parallèle : le principal (dictée
/// normale) et un second, optionnel, pour l'action alternative.
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let mainRunLoop = CFRunLoopGetMain()
    private let callback: (HotkeyRole, Bool) -> Void

    /// État par rôle, lu et écrit uniquement depuis la run loop principale
    private var pressed: [HotkeyRole: Bool] = [:]

    private var primary: HotkeyChoice
    private var secondary: HotkeyChoice?

    private static let logger = Logger(subsystem: "com.whispered", category: "HotkeyManager")

    init(callback: @escaping (HotkeyRole, Bool) -> Void) {
        self.callback = callback
        self.primary = HotkeySettingsManager.shared.hotkeyChoice
        self.secondary = HotkeySettingsManager.shared.secondaryHotkeyChoice
    }

    /// Met à jour les touches surveillées, tap en cours de fonctionnement inclus.
    func updateHotkeys(primary: HotkeyChoice, secondary: HotkeyChoice?) {
        // Un raccourci qui change alors qu'il est enfoncé laisserait un
        // enregistrement bloqué : on relâche proprement avant de basculer.
        for (role, isDown) in pressed where isDown {
            pressed[role] = false
            callback(role, false)
        }
        self.primary = primary
        self.secondary = (secondary == primary) ? nil : secondary
        Self.logger.info("Raccourcis: \(primary.displayName, privacy: .public) / \(secondary?.displayName ?? "aucun", privacy: .public)")
    }

    // MARK: - Cycle de vie

    func start() -> Bool {
        if eventTap != nil {
            Self.logger.info("Tap déjà actif")
            return true
        }

        guard AXIsProcessTrusted() else {
            Self.logger.error("Permission d'accessibilité absente, tap impossible")
            return false
        }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,  // Accessibilité suffit, pas besoin d'Input Monitoring
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("Création du tap CGEvent échouée")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        guard let runLoopSource else {
            Self.logger.error("Création de la source de run loop échouée")
            eventTap = nil
            return false
        }

        CFRunLoopAddSource(mainRunLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.logger.info("Tap CGEvent actif")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(mainRunLoop, runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pressed.removeAll()
        Self.logger.info("Tap arrêté")
    }

    // MARK: - Traitement des événements

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Le système désactive le tap s'il met trop longtemps à répondre
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.warning("Tap désactivé par le système, réactivé")
            }
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        for (role, choice) in roles() where choice.keyCode == keyCode {
            switch type {
            case .flagsChanged:
                handleFlagsChanged(role: role, choice: choice, flags: event.flags)
            case .keyDown:
                if choice.usesKeyEvents { setPressed(role, true) }
            case .keyUp:
                if choice.usesKeyEvents { setPressed(role, false) }
            default:
                break
            }
        }
    }

    private func roles() -> [(HotkeyRole, HotkeyChoice)] {
        var result: [(HotkeyRole, HotkeyChoice)] = [(.primary, primary)]
        if let secondary {
            result.append((.secondary, secondary))
        }
        return result
    }

    private func handleFlagsChanged(role: HotkeyRole, choice: HotkeyChoice, flags: CGEventFlags) {
        guard let mask = choice.deviceFlagMask ?? choice.flagMask else { return }
        setPressed(role, flags.contains(mask))
    }

    private func setPressed(_ role: HotkeyRole, _ isDown: Bool) {
        guard pressed[role, default: false] != isDown else { return }
        pressed[role] = isDown
        callback(role, isDown)
    }

    deinit {
        stop()
    }
}

// MARK: - Masques par touche physique

extension HotkeyChoice {
    /// Les touches de fonction passent par keyDown/keyUp, pas par flagsChanged.
    var usesKeyEvents: Bool {
        isFunctionKey || self == .fn
    }

    /// Masque distinguant la touche gauche de la droite.
    ///
    /// `flagMask` seul ne suffit pas : ⌘ gauche et ⌘ droite partagent
    /// `.maskCommand`, donc relâcher la droite alors que la gauche est enfoncée
    /// laissait l'app croire que le raccourci était toujours actif. Ces masques
    /// dépendants du périphérique (IOKit `NX_DEVICE*KEYMASK`) lèvent l'ambiguïté.
    var deviceFlagMask: CGEventFlags? {
        switch self {
        case .leftControl:  return CGEventFlags(rawValue: 0x0000_0001)
        case .leftShift:    return CGEventFlags(rawValue: 0x0000_0002)
        case .rightShift:   return CGEventFlags(rawValue: 0x0000_0004)
        case .leftCommand:  return CGEventFlags(rawValue: 0x0000_0008)
        case .rightCommand: return CGEventFlags(rawValue: 0x0000_0010)
        case .leftOption:   return CGEventFlags(rawValue: 0x0000_0020)
        case .rightOption:  return CGEventFlags(rawValue: 0x0000_0040)
        case .rightControl: return CGEventFlags(rawValue: 0x0000_2000)
        default:            return nil
        }
    }
}
