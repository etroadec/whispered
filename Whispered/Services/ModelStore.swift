import AppKit
import Foundation
import os.log

/// Logger hors acteur : utilisé aussi depuis les rappels de téléchargement.
private let storeLogger = Logger(subsystem: "com.whispered", category: "ModelStore")

/// Progression d'un téléchargement de modèle.
struct ModelDownloadProgress {
    let model: TranscriptionModel
    let bytesReceived: Int64
    let bytesExpected: Int64

    var fraction: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }

    var description: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: bytesReceived)
        let total = formatter.string(fromByteCount: bytesExpected)
        return "\(received) sur \(total)"
    }
}

enum ModelStoreError: LocalizedError {
    case downloadFailed(String)
    case unexpectedSize(expected: Int64, actual: Int64)
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return "Téléchargement échoué : \(detail)"
        case .unexpectedSize(let expected, let actual):
            return "Fichier incomplet : \(actual) octets reçus au lieu d'environ \(expected)."
        case .writeFailed(let detail):
            return "Écriture impossible : \(detail)"
        case .cancelled:
            return "Téléchargement annulé"
        }
    }
}

/// Gère les fichiers de modèles sur le disque et leur téléchargement.
///
/// La version précédente lançait un `URLSession.downloadTask` sans observer sa
/// progression : l'utilisateur voyait « Téléchargement… » pendant plusieurs
/// minutes pour 1,6 Go, sans barre, sans annulation, et sans contrôle de ce qui
/// avait été reçu.
@MainActor
final class ModelStore: NSObject, ObservableObject {
    static let shared = ModelStore()

    /// Progression par modèle en cours de téléchargement
    @Published private(set) var progress: [TranscriptionModel: ModelDownloadProgress] = [:]

    private var tasks: [TranscriptionModel: URLSessionDownloadTask] = [:]
    private var completions: [Int: (Result<URL, ModelStoreError>) -> Void] = [:]
    private var modelsByTaskID: [Int: TranscriptionModel] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()


    private override init() {
        super.init()
    }

    // MARK: - Emplacements

    /// Calculé une fois : c'était un getter qui créait le répertoire à chaque
    /// accès, soit un `mkdir` par modèle et par ouverture de menu.
    nonisolated static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whispered/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static func path(for model: TranscriptionModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// Les 4 premiers octets d'un modèle ggml, whisper comme parakeet : « lmgg ».
    /// Une page d'erreur HTML enregistrée sous le nom du modèle ne les a pas.
    nonisolated static let ggmlMagic: [UInt8] = [0x6c, 0x6d, 0x67, 0x67]

    /// Un fichier présent ne suffit pas : un portail captif laisse une page HTML
    /// sous le nom du modèle, et un téléchargement interrompu un fichier tronqué.
    ///
    /// On ne compare **pas** à une taille attendue codée en dur : si l'amont
    /// republie le même modèle légèrement plus petit, l'app refuserait pour
    /// toujours un fichier parfaitement valide, sans aucune issue depuis l'UI.
    /// La troncature est détectée au téléchargement, en comparant ce qui est
    /// reçu à ce que le serveur annonce.
    nonisolated static func isValidModelFile(at url: URL, expectedBytes: Int64 = 0) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64,
              size > 500_000 else {
            return false
        }
        return hasGGMLMagic(at: url)
    }

    /// Validité mise en cache : `isInstalled` est appelée à chaque passe de
    /// rendu SwiftUI, et sur le chemin du raccourci clavier. Trois appels
    /// système par vérification, des dizaines de fois par seconde pendant un
    /// téléchargement, c'est non.
    private struct ValidityCache: Sendable {
        let size: Int64
        let modified: Date
        let isValid: Bool
    }

    nonisolated private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var validityCache: [String: ValidityCache] = [:]

    nonisolated private static func cachedValidity(of url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64,
              let modified = attributes[.modificationDate] as? Date else {
            cacheLock.withLock { validityCache[url.path] = nil }
            return false
        }

        if let cached = cacheLock.withLock({ validityCache[url.path] }),
           cached.size == size, cached.modified == modified {
            return cached.isValid
        }

        let valid = size > 500_000 && hasGGMLMagic(at: url)
        cacheLock.withLock {
            validityCache[url.path] = ValidityCache(size: size, modified: modified, isValid: valid)
        }
        return valid
    }

    /// À appeler après toute écriture ou suppression dans le dossier.
    nonisolated static func invalidateValidityCache() {
        cacheLock.withLock { validityCache.removeAll() }
    }

    nonisolated static func hasGGMLMagic(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return false }
        return Array(header) == ggmlMagic
    }

    nonisolated static func isInstalled(_ model: TranscriptionModel) -> Bool {
        cachedValidity(of: path(for: model))
    }

    func installedSize(of model: TranscriptionModel) -> String? {
        let url = Self.path(for: model)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    // MARK: - Modèles retirés du catalogue

    /// Tout ce qui occupe de la place dans le dossier des modèles sans servir à
    /// l'app : anciens modèles whisper, variantes jamais proposées, encodeurs
    /// CoreML devenus inutiles, téléchargements interrompus.
    ///
    /// Balayage du dossier avec liste blanche, et non liste noire en dur : une
    /// liste figée ne verrait ni `ggml-large-v2.bin`, ni `ggml-base.en.bin`, ni
    /// un `.part` abandonné.
    func retiredModelFiles() -> [(name: String, bytes: Int64)] {
        let fm = FileManager.default
        var keep = Set(TranscriptionModel.allCases.map(\.fileName))
        keep.insert(VoiceActivityDetector.modelFileName)

        guard let contents = try? fm.contentsOfDirectory(
            at: Self.modelsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .totalFileAllocatedSizeKey]
        ) else {
            return []
        }

        return contents.compactMap { url in
            let name = url.lastPathComponent
            guard !keep.contains(name), !name.hasPrefix(".DS") else { return nil }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
            if values?.isDirectory == true {
                // Un encodeur CoreML est un paquet : on somme son contenu
                guard name.hasSuffix(".mlmodelc") else { return nil }
                return (name, Self.directorySize(of: url))
            }
            guard let size = values?.fileSize.map(Int64.init) else { return nil }
            return (name, size)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    nonisolated private static func directorySize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Supprime un fichier récupérable précis. L'appelant demande confirmation.
    func deleteRetiredFile(named name: String) throws {
        let url = Self.modelsDirectory.appendingPathComponent(name)
        try FileManager.default.removeItem(at: url)
        Self.invalidateValidityCache()
        storeLogger.info("Fichier supprimé : \(name, privacy: .public)")
        objectWillChange.send()
    }

    func deleteRetiredModelFiles(_ names: [String]) {
        for name in names {
            do {
                try deleteRetiredFile(named: name)
            } catch {
                storeLogger.error("Suppression de \(name, privacy: .public) impossible")
            }
        }
    }

    /// Ouvre le dossier des modèles sur un fichier précis.
    func revealInFinder(_ name: String) {
        let url = Self.modelsDirectory.appendingPathComponent(name)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func delete(_ model: TranscriptionModel) throws {
        let url = Self.path(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        Self.invalidateValidityCache()
        objectWillChange.send()
    }

    // MARK: - Téléchargement

    /// Fichier où est gardé le jeton de reprise d'un téléchargement annulé.
    /// Hugging Face sert les requêtes par plage : reprendre 600 Mo au lieu de
    /// les retélécharger change tout quand la connexion saute.
    nonisolated private static func resumeDataPath(for model: TranscriptionModel) -> URL {
        modelsDirectory.appendingPathComponent(".\(model.fileName).resume")
    }

    func download(_ model: TranscriptionModel, completion: @escaping (Result<URL, ModelStoreError>) -> Void) {
        if Self.isInstalled(model) {
            completion(.success(Self.path(for: model)))
            return
        }
        guard tasks[model] == nil else { return }

        let resumePath = Self.resumeDataPath(for: model)
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumePath) {
            storeLogger.info("Reprise du téléchargement de \(model.fileName, privacy: .public)")
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: model.downloadURL)
        }
        tasks[model] = task
        modelsByTaskID[task.taskIdentifier] = model
        completions[task.taskIdentifier] = completion
        progress[model] = ModelDownloadProgress(
            model: model,
            bytesReceived: 0,
            bytesExpected: model.expectedBytes
        )
        task.resume()
        storeLogger.info("Téléchargement lancé : \(model.fileName, privacy: .public)")
    }

    /// Télécharge le modèle VAD (0,9 Mo) en vérifiant ce qui arrive.
    ///
    /// Sans ces contrôles, un 404 ou un portail captif installait une page HTML
    /// sous le nom `ggml-silero-v5.1.2.bin` : le VAD échouait alors à chaque
    /// dictée, sans message et sans moyen de se réparer, puisque le fichier
    /// existait bel et bien.
    func downloadVADModelIfNeeded() {
        let destination = VoiceActivityDetector.modelPath

        // Un fichier invalide laissé par un téléchargement précédent est écarté
        if FileManager.default.fileExists(atPath: destination.path),
           !Self.isValidModelFile(at: destination) {
            storeLogger.notice("Modèle VAD invalide, suppression et nouvel essai")
            try? FileManager.default.removeItem(at: destination)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let task = URLSession.shared.downloadTask(with: VoiceActivityDetector.modelURL) { tempURL, response, error in
            guard let tempURL else {
                storeLogger.error("Téléchargement du VAD échoué : \(error?.localizedDescription ?? "sans réponse", privacy: .public)")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                storeLogger.error("Téléchargement du VAD : HTTP \(statusCode, privacy: .public)")
                return
            }
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(VoiceActivityDetector.modelFileName).part")
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.moveItem(at: tempURL, to: staging)
            } catch {
                storeLogger.error("VAD : écriture impossible (\(error.localizedDescription, privacy: .public))")
                return
            }
            guard Self.isValidModelFile(at: staging) else {
                storeLogger.error("VAD : fichier reçu invalide, ignoré")
                try? FileManager.default.removeItem(at: staging)
                return
            }
            do {
                try Self.install(staging, at: destination)
                storeLogger.info("Modèle VAD installé")
            } catch {
                storeLogger.error("VAD : installation impossible (\(error.localizedDescription, privacy: .public))")
                try? FileManager.default.removeItem(at: staging)
            }
        }
        task.resume()
    }

    /// Met un fichier en place sans fenêtre pendant laquelle le modèle n'existe
    /// plus : `removeItem` puis `moveItem` laisse l'utilisateur sans rien si
    /// l'app meurt entre les deux.
    nonisolated static func install(_ source: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func cancel(_ model: TranscriptionModel) {
        guard let task = tasks[model] else { return }
        let resumePath = Self.resumeDataPath(for: model)
        task.cancel { data in
            guard let data else { return }
            try? data.write(to: resumePath, options: .atomic)
        }
        finish(taskID: task.taskIdentifier, model: model, result: .failure(.cancelled))
    }

    private func finish(taskID: Int, model: TranscriptionModel, result: Result<URL, ModelStoreError>) {
        let completion = completions.removeValue(forKey: taskID)
        tasks.removeValue(forKey: model)
        modelsByTaskID.removeValue(forKey: taskID)
        progress.removeValue(forKey: model)
        completion?(result)
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let model = self.modelsByTaskID[taskID] else { return }
            // `totalBytesExpectedToWrite` vaut -1 si le serveur ne l'annonce pas :
            // on retombe sur la taille attendue du catalogue.
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.expectedBytes
            self.progress[model] = ModelDownloadProgress(
                model: model,
                bytesReceived: totalBytesWritten,
                bytesExpected: expected
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // Ce que le serveur a annoncé, et non une constante du catalogue
        let announced = downloadTask.response?.expectedContentLength ?? -1
        let receivedBytes = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int64) ?? 0

        // Le fichier temporaire disparaît au retour de cette méthode : on le
        // déplace tout de suite, hors du main actor.
        // Staging dans le dossier des modèles : même volume, donc un rename(2)
        // atomique à l'installation plutôt qu'une recopie depuis /tmp.
        let staging = Self.modelsDirectory
            .appendingPathComponent(".download-\(UUID().uuidString).part")
        var moveError: String?
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            moveError = error.localizedDescription
        }

        Task { @MainActor in
            // Téléchargement annulé entre-temps : sans ce ménage, 670 Mo de
            // `.part` restent dans le dossier des modèles pour toujours.
            guard let model = self.modelsByTaskID[taskID] else {
                try? FileManager.default.removeItem(at: staging)
                return
            }

            if let moveError {
                self.finish(taskID: taskID, model: model, result: .failure(.writeFailed(moveError)))
                return
            }
            guard (200...299).contains(statusCode) else {
                try? FileManager.default.removeItem(at: staging)
                self.finish(taskID: taskID, model: model, result: .failure(.downloadFailed("HTTP \(statusCode)")))
                return
            }
            // Reçu complet par rapport à ce que le serveur annonçait, et
            // signature du format correcte.
            let complete = announced <= 0 || receivedBytes >= announced
            guard complete, Self.isValidModelFile(at: staging) else {
                // Fichier inexploitable : le jeton de reprise ne vaut plus rien
                try? FileManager.default.removeItem(at: Self.resumeDataPath(for: model))
                try? FileManager.default.removeItem(at: staging)
                self.finish(
                    taskID: taskID,
                    model: model,
                    result: .failure(.unexpectedSize(expected: model.expectedBytes, actual: receivedBytes))
                )
                return
            }

            let destination = Self.path(for: model)
            do {
                try Self.install(staging, at: destination)
                Self.invalidateValidityCache()
                try? FileManager.default.removeItem(at: Self.resumeDataPath(for: model))
                storeLogger.info("Modèle installé : \(model.fileName, privacy: .public)")
                self.finish(taskID: taskID, model: model, result: .success(destination))
            } catch {
                try? FileManager.default.removeItem(at: staging)
                self.finish(taskID: taskID, model: model, result: .failure(.writeFailed(error.localizedDescription)))
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        let isCancellation = (error as NSError).code == NSURLErrorCancelled
        let message = error.localizedDescription

        Task { @MainActor in
            guard let model = self.modelsByTaskID[taskID] else { return }
            self.finish(
                taskID: taskID,
                model: model,
                result: .failure(isCancellation ? .cancelled : .downloadFailed(message))
            )
        }
    }
}
