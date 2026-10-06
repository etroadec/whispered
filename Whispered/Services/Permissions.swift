import AVFoundation
import AppKit
import ApplicationServices
import Foundation

/// État des deux permissions dont l'app a besoin, et moyens de les obtenir.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum State {
        case granted
        case denied
        case notRequested

        var isGranted: Bool { self == .granted }
    }

    @Published private(set) var microphone: State = .notRequested
    @Published private(set) var accessibility: State = .notRequested

    /// Les deux permissions sont accordées : l'app est pleinement fonctionnelle
    var allGranted: Bool { microphone.isGranted && accessibility.isGranted }

    private var pollTimer: Timer?

    private init() {
        refresh()
    }

    // MARK: - Lecture

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notRequested
        default: microphone = .denied
        }

        // Pas d'API pour distinguer « refusé » de « jamais demandé » côté
        // accessibilité : on retient seulement accordé ou non.
        accessibility = AXIsProcessTrusted() ? .granted : .notRequested
    }

    /// Surveille les changements faits dans Réglages Système, qui ne notifient rien.
    func startMonitoring() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let wasGranted = self.allGranted
                self.refresh()
                if self.allGranted && !wasGranted {
                    NotificationCenter.default.post(name: .permissionsDidBecomeComplete, object: nil)
                }
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Demandes

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Déclenche l'invite système d'accessibilité (une seule fois par app, ensuite
    /// il faut passer par Réglages Système).
    func promptAccessibility() {
        // `kAXTrustedCheckOptionPrompt` est un `var` global du SDK, donc
        // inaccessible en Swift 6 strict : la clé littérale est stable depuis
        // toujours et documentée dans ApplicationServices.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        startMonitoring()
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // Pas de `deinit` qui touche au timer : ce singleton vit aussi longtemps que
    // l'app, et `stopMonitoring()` est appelé explicitement à la fermeture.
}

extension Notification.Name {
    static let permissionsDidBecomeComplete = Notification.Name("permissionsDidBecomeComplete")
}
