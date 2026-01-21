import Carbon
import Cocoa
import Foundation

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callback: (Bool) -> Void
    private var isRightCommandPressed = false

    // Key codes
    private static let kVK_RightCommand: CGKeyCode = 0x36

    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }

    func start() {
        // Create event tap to capture key events globally
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Make sure accessibility permissions are granted.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func stop() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Check for Right Command key
        if keyCode == Self.kVK_RightCommand {
            let isPressed = flags.contains(.maskCommand)

            if isPressed && !isRightCommandPressed {
                isRightCommandPressed = true
                DispatchQueue.main.async { [weak self] in
                    self?.callback(true)
                }
            } else if !isPressed && isRightCommandPressed {
                isRightCommandPressed = false
                DispatchQueue.main.async { [weak self] in
                    self?.callback(false)
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    deinit {
        stop()
    }
}
