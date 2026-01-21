import AppKit
import Carbon
import Foundation

class TextInjector {
    static let shared = TextInjector()

    private init() {}

    func injectText(_ text: String) {
        // Method 1: Use pasteboard and paste
        injectViaPasteboard(text)
    }

    private func injectViaPasteboard(_ text: String) {
        // Save current pasteboard content and change count
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        // Set new content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore previous content after a delay
        // But only if pasteboard hasn't been modified by user since our paste
        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // changeCount increments by 1 for clearContents, +1 for setString = +2 total
                // Only restore if no external change occurred
                if pasteboard.changeCount == previousChangeCount + 2 {
                    pasteboard.clearContents()
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key down: Cmd+V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up: Cmd+V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    // Alternative method using CGEvent for direct character input
    func injectTextDirectly(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)

        for character in text {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { continue }

            var unicodeString = [UniChar](String(character).utf16)
            event.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: &unicodeString)
            event.post(tap: .cghidEventTap)

            // Key up
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.post(tap: .cghidEventTap)

            // Small delay between characters
            usleep(1000)
        }
    }
}
