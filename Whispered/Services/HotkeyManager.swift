import Carbon
import Cocoa
import Foundation
import os.log

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let mainRunLoop = CFRunLoopGetMain()
    private var callback: (Bool) -> Void
    
    // State - only accessed from main run loop, no need for queue
    private var isKeyPressed = false
    
    // Current hotkey configuration - read from settings
    private var currentHotkey: HotkeyChoice
    
    private static let logger = Logger(subsystem: "com.whispered", category: "HotkeyManager")
    
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
        self.currentHotkey = HotkeySettingsManager.shared.hotkeyChoice
    }
    
    /// Update the hotkey being monitored (can be called while running)
    func updateHotkey(_ newHotkey: HotkeyChoice) {
        // Reset state when changing hotkey
        if isKeyPressed {
            isKeyPressed = false
            callback(false)
        }
        currentHotkey = newHotkey
        Self.logger.info("Hotkey updated to: \(newHotkey.displayName)")
        print("HotkeyManager: Hotkey updated to \(newHotkey.displayName)")
    }
    
    func start() -> Bool {
        // Check if we already have an event tap
        if eventTap != nil {
            Self.logger.info("Event tap already exists")
            print("HotkeyManager: Event tap already exists")
            return true
        }
        
        // Verify accessibility permission first
        let trusted = AXIsProcessTrusted()
        print("HotkeyManager: AXIsProcessTrusted = \(trusted)")
        Self.logger.info("AXIsProcessTrusted = \(trusted)")
        
        guard trusted else {
            Self.logger.error("Cannot create event tap: Accessibility permission not granted")
            print("HotkeyManager: FAILED - No accessibility permission")
            return false
        }
        
        // Create event tap using defaultTap (requires Accessibility permission only)
        // listenOnly requires Input Monitoring permission which is separate
        // We listen to flagsChanged for modifier keys AND keyDown/keyUp for Fn key
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue)
        
        Self.logger.info("Creating event tap...")
        print("HotkeyManager: Creating event tap with defaultTap...")
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,  // Uses Accessibility permission (not Input Monitoring)
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleEvent(proxy: proxy, type: type, event: event)
                // Return the event unchanged (we're not modifying it, just observing)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("FAILED to create event tap!")
            print("HotkeyManager: FAILED to create event tap!")
            return false
        }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        
        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(mainRunLoop, runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.logger.info("Event tap created successfully!")
            print("HotkeyManager: Event tap created successfully! Listening for \(currentHotkey.displayName) key.")
            return true
        }
        
        Self.logger.error("Failed to create run loop source")
        print("HotkeyManager: Failed to create run loop source")
        return false
    }
    
    func stop() {
        // FIRST: Disable the tap so no more events come in
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        // THEN: Remove from run loop
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(mainRunLoop, runLoopSource, .commonModes)
        }
        
        // THEN: Clean up references
        eventTap = nil
        runLoopSource = nil
        isKeyPressed = false
        Self.logger.info("Event tap stopped")
    }
    
    func isActive() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        // Handle tap being disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Self.logger.warning("Event tap was disabled, re-enabling")
            }
            return
        }
        
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let targetKeyCode = currentHotkey.keyCode
        
        // Check if this is our target key
        guard keyCode == targetKeyCode else { return }
        
        // Handle the key based on type
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)

        case .keyDown:
            // Pour les touches de fonction (F1-F12) et Fn qui utilisent keyDown/keyUp
            if currentHotkey.isFunctionKey || currentHotkey == .fn {
                if !isKeyPressed {
                    isKeyPressed = true
                    callback(true)
                }
            }

        case .keyUp:
            // Pour les touches de fonction (F1-F12) et Fn qui utilisent keyDown/keyUp
            if currentHotkey.isFunctionKey || currentHotkey == .fn {
                if isKeyPressed {
                    isKeyPressed = false
                    callback(false)
                }
            }

        default:
            break
        }
    }
    
    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        
        // Determine if key is pressed based on the flag mask
        let isPressed: Bool
        
        if let flagMask = currentHotkey.flagMask {
            isPressed = flags.contains(flagMask)
        } else {
            // Fallback for keys without a standard flag mask
            // This shouldn't happen with our current key choices
            return
        }
        
        // Emit callback only on state change
        if isPressed && !isKeyPressed {
            isKeyPressed = true
            callback(true)
        } else if !isPressed && isKeyPressed {
            isKeyPressed = false
            callback(false)
        }
    }
    
    deinit {
        stop()
    }
}
