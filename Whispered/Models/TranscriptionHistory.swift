import Foundation
import os.log

/// Logger hors acteur : l'écriture du fichier se fait sur une tâche détachée.
private let historyLogger = Logger(subsystem: "com.whispered", category: "History")

/// Une dictée enregistrée dans l'historique.
struct TranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    /// Nom du moteur qui a produit le texte ("Parakeet", "Whisper", …)
    let engine: String
    /// Langue détectée ou imposée, nil si inconnue
    let language: String?
    /// Durée de l'audio dicté
    let audioDuration: TimeInterval
    /// Temps de transcription, pour afficher la latence réelle
    let processingTime: TimeInterval

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        engine: String,
        language: String? = nil,
        audioDuration: TimeInterval,
        processingTime: TimeInterval
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.engine = engine
        self.language = language
        self.audioDuration = audioDuration
        self.processingTime = processingTime
    }

    /// Aperçu sur une ligne pour les listes et le menu
    var preview: String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 80 ? flat : String(flat.prefix(79)) + "…"
    }

    /// Vitesse de transcription relative au temps réel (x12 = 12 fois plus vite que la parole)
    var realtimeFactor: Double? {
        guard processingTime > 0, audioDuration > 0 else { return nil }
        return audioDuration / processingTime
    }
}

/// Historique local des dictées, persisté en JSON dans Application Support.
///
/// Les entrées sont triées de la plus récente à la plus ancienne et plafonnées à
/// `maxEntries`. Tout l'accès se fait sur le main actor : l'historique est lu par
/// l'interface, et une dictée toutes les quelques secondes ne justifie pas mieux.
@MainActor
final class TranscriptionHistory: ObservableObject {
    static let shared = TranscriptionHistory()

    /// Nombre maximum d'entrées conservées
    static let maxEntries = 50

    @Published private(set) var entries: [TranscriptionEntry] = []

    /// Conservation de l'historique : désactivable pour les usages sensibles
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { clear() }
        }
    }

    private static let enabledKey = "historyEnabled"

    private var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whispered", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        // Activé par défaut : l'app est 100 % locale, l'historique ne sort pas de la machine
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        load()
    }

    // MARK: - Lecture / écriture

    func add(_ entry: TranscriptionEntry) {
        guard isEnabled, !entry.text.isEmpty else { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func remove(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Recherche insensible à la casse et aux accents
    func search(_ query: String) -> [TranscriptionEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var mostRecent: TranscriptionEntry? { entries.first }

    // MARK: - Persistance

    private func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([TranscriptionEntry].self, from: data)
        } catch {
            historyLogger.error("Lecture de l'historique impossible: \(error.localizedDescription, privacy: .public)")
            // Fichier corrompu : on repart d'un historique vide plutôt que de bloquer l'app
            entries = []
        }
    }

    private func save() {
        let snapshot = entries
        let url = fileURL
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .withoutEscapingSlashes
                let data = try encoder.encode(snapshot)
                // Écriture atomique : pas d'historique à moitié écrit si l'app est tuée
                try data.write(to: url, options: .atomic)
            } catch {
                historyLogger.error("Écriture de l'historique impossible: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
