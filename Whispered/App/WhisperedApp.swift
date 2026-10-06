import SwiftUI

@main
struct WhisperedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Toute l'interface est pilotée par l'`AppDelegate` : l'app vit dans la
    /// barre des menus, ses fenêtres sont des `NSWindow` qu'il crée et retient.
    /// `App` exige au moins une scène, d'où cette scène vide — la précédente
    /// déclarait un `Settings { SettingsView() }` inatteignable, l'app n'ayant
    /// pas de menu principal, et qui aurait ouvert une seconde fenêtre de
    /// préférences concurrente de celle de l'AppDelegate.
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
