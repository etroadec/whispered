---
description: Développement d'applications menu bar macOS
---

# Skill: macOS Menu Bar Apps

Ce skill fournit des patterns pour développer des applications menu bar sur macOS.

## Structure de base

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cacher du Dock
        NSApp.setActivationPolicy(.accessory)

        // Créer l'élément de menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "icon", accessibilityDescription: "App")
        }
    }
}
```

## Popover vs Menu

- **Popover**: Pour du contenu interactif (SwiftUI views)
- **Menu**: Pour des actions simples (NSMenu)

```swift
// Popover
let popover = NSPopover()
popover.contentViewController = NSHostingController(rootView: MyView())
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

// Menu
let menu = NSMenu()
menu.addItem(NSMenuItem(title: "Action", action: #selector(action), keyEquivalent: ""))
statusItem?.menu = menu
```

## Raccourcis clavier globaux

Utiliser `CGEvent.tapCreate` pour capturer les touches globalement:
```swift
let eventMask = (1 << CGEventType.keyDown.rawValue)
CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(eventMask),
    callback: { ... },
    userInfo: nil
)
```

**Note**: Requiert les permissions d'accessibilité.
