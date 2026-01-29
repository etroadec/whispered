import Foundation
import AppKit
import os.log

// MARK: - Update Errors

enum UpdateError: LocalizedError {
    case networkError(String)
    case invalidResponse
    case noReleasesFound
    case assetNotFound
    case downloadFailed(String)
    case extractionFailed(String)
    case installationFailed(String)
    case alreadyUpToDate
    case invalidVersion
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Erreur réseau: \(message)"
        case .invalidResponse:
            return "Réponse invalide du serveur GitHub"
        case .noReleasesFound:
            return "Aucune release trouvée sur GitHub"
        case .assetNotFound:
            return "Asset .zip non trouvé dans la release"
        case .downloadFailed(let message):
            return "Échec du téléchargement: \(message)"
        case .extractionFailed(let message):
            return "Échec de l'extraction: \(message)"
        case .installationFailed(let message):
            return "Échec de l'installation: \(message)"
        case .alreadyUpToDate:
            return "L'application est déjà à jour"
        case .invalidVersion:
            return "Version invalide"
        case .cancelled:
            return "Mise à jour annulée"
        }
    }
}

// MARK: - GitHub Release Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let body: String?
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String?
    let assets: [GitHubAsset]
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case prerelease
        case draft
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let size: Int
    let browserDownloadUrl: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadUrl = "browser_download_url"
    }
}

// MARK: - Update Info

struct UpdateInfo {
    let version: String
    let releaseNotes: String?
    let downloadURL: URL
    let fileSize: Int
    let publishedAt: Date?
    
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }
}

// MARK: - Update Progress

struct UpdateProgress {
    let phase: Phase
    let progress: Double  // 0.0 to 1.0
    let bytesDownloaded: Int64
    let totalBytes: Int64
    
    enum Phase: String {
        case checking = "Vérification..."
        case downloading = "Téléchargement..."
        case extracting = "Extraction..."
        case installing = "Installation..."
        case restarting = "Redémarrage..."
    }
    
    var description: String {
        switch phase {
        case .downloading:
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB]
            formatter.countStyle = .file
            let downloaded = formatter.string(fromByteCount: bytesDownloaded)
            let total = formatter.string(fromByteCount: totalBytes)
            return "\(phase.rawValue) \(downloaded) / \(total)"
        default:
            return phase.rawValue
        }
    }
}

// MARK: - Semantic Version Comparison

struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?
    
    init?(string: String) {
        // Remove "v" prefix if present
        var versionString = string
        if versionString.hasPrefix("v") || versionString.hasPrefix("V") {
            versionString = String(versionString.dropFirst())
        }
        
        // Split prerelease suffix (e.g., "1.2.3-beta1")
        let parts = versionString.split(separator: "-", maxSplits: 1)
        let mainVersion = String(parts[0])
        self.prerelease = parts.count > 1 ? String(parts[1]) : nil
        
        // Parse major.minor.patch
        let components = mainVersion.split(separator: ".").compactMap { Int($0) }
        
        guard components.count >= 1 else { return nil }
        
        self.major = components[0]
        self.minor = components.count > 1 ? components[1] : 0
        self.patch = components.count > 2 ? components[2] : 0
    }
    
    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        
        // Prerelease versions are always less than release versions
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false  // Release > prerelease
        case (_, nil): return true   // Prerelease < release
        case (let l?, let r?): return l < r
        }
    }
}

// MARK: - Update Service

class UpdateService: NSObject {
    static let shared = UpdateService()
    
    // Configuration
    private(set) var githubOwner: String = "etroadec"
    private(set) var githubRepo: String = "whispered"
    
    // State (synchronized via stateLock)
    private let stateLock = NSLock()
    private var downloadTask: URLSessionDownloadTask?
    private var progressHandler: ((UpdateProgress) -> Void)?
    private var _isCancelled = false

    private var isCancelled: Bool {
        get { stateLock.withLock { _isCancelled } }
        set { stateLock.withLock { _isCancelled = newValue } }
    }
    
    // Session with delegate for progress tracking
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600  // 10 minutes max for large downloads
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    private static let logger = Logger(subsystem: "com.whispered", category: "UpdateService")
    
    private override init() {
        super.init()
        
        // Allow override from UserDefaults (for testing)
        if let owner = UserDefaults.standard.string(forKey: "UpdateGitHubOwner"), !owner.isEmpty {
            githubOwner = owner
        }
        if let repo = UserDefaults.standard.string(forKey: "UpdateGitHubRepo"), !repo.isEmpty {
            githubRepo = repo
        }
    }
    
    // MARK: - Public API
    
    /// Configure the GitHub repository for updates
    func configure(owner: String, repo: String) {
        self.githubOwner = owner
        self.githubRepo = repo
    }
    
    /// Get the current app version from Info.plist
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    
    /// Check for updates without downloading
    func checkForUpdate(
        includePrerelease: Bool = false,
        completion: @escaping (Result<UpdateInfo?, UpdateError>) -> Void
    ) {
        Self.logger.info("Checking for updates...")
        
        fetchLatestRelease(includePrerelease: includePrerelease) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let release):
                guard let updateInfo = self.parseRelease(release) else {
                    Self.logger.info("No valid asset found in release")
                    completion(.failure(.assetNotFound))
                    return
                }
                
                // Compare versions
                guard let remoteVersion = SemanticVersion(string: release.tagName),
                      let localVersion = SemanticVersion(string: self.currentVersion) else {
                    Self.logger.error("Invalid version format")
                    completion(.failure(.invalidVersion))
                    return
                }
                
                if remoteVersion > localVersion {
                    Self.logger.info("Update available: \(release.tagName) (current: \(self.currentVersion))")
                    completion(.success(updateInfo))
                } else {
                    Self.logger.info("Already up to date (\(self.currentVersion))")
                    completion(.success(nil))  // nil = no update available
                }
                
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Download and install an update
    func downloadAndInstall(
        update: UpdateInfo,
        progress: @escaping (UpdateProgress) -> Void,
        completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        isCancelled = false
        progressHandler = progress
        
        Self.logger.info("Starting update download: \(update.version)")
        progress(UpdateProgress(phase: .downloading, progress: 0, bytesDownloaded: 0, totalBytes: Int64(update.fileSize)))
        
        let request = URLRequest(url: update.downloadURL)
        downloadTask = downloadSession.downloadTask(with: request) { [weak self] tempURL, response, error in
            // Le completion handler est appelé sur une queue background, dispatch sur main
            DispatchQueue.main.async {
                guard let self = self else { return }

                if self.isCancelled {
                    completion(.failure(.cancelled))
                    return
                }

                if let error = error {
                    Self.logger.error("Download failed: \(error.localizedDescription)")
                    completion(.failure(.downloadFailed(error.localizedDescription)))
                    return
                }

                guard let tempURL = tempURL else {
                    completion(.failure(.downloadFailed("No file received")))
                    return
                }

                // Copier le fichier temporaire car il sera supprimé après le retour de ce callback
                let persistentTempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".zip")
                do {
                    try FileManager.default.copyItem(at: tempURL, to: persistentTempURL)
                    // Continue with extraction and installation
                    self.extractAndInstall(from: persistentTempURL, progress: progress, completion: completion)
                } catch {
                    Self.logger.error("Failed to preserve download: \(error.localizedDescription)")
                    completion(.failure(.downloadFailed("Failed to preserve download: \(error.localizedDescription)")))
                }
            }
        }
        
        downloadTask?.resume()
    }
    
    /// Cancel an ongoing download
    func cancelUpdate() {
        isCancelled = true
        downloadTask?.cancel()
        downloadTask = nil
        progressHandler = nil
        Self.logger.info("Update cancelled by user")
    }
    
    // MARK: - Private Methods
    
    private func fetchLatestRelease(
        includePrerelease: Bool,
        completion: @escaping (Result<GitHubRelease, UpdateError>) -> Void
    ) {
        let urlString = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases"
        
        guard let url = URL(string: urlString) else {
            completion(.failure(.invalidResponse))
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Whispered/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    Self.logger.error("Network error: \(error.localizedDescription)")
                    completion(.failure(.networkError(error.localizedDescription)))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    Self.logger.error("GitHub API returned status \(httpResponse.statusCode)")
                    completion(.failure(.networkError("HTTP \(httpResponse.statusCode)")))
                    return
                }
                
                guard let data = data else {
                    completion(.failure(.invalidResponse))
                    return
                }
                
                do {
                    let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                    
                    // Filter releases: no drafts, optionally no prereleases
                    let validReleases = releases.filter { release in
                        !release.draft && (includePrerelease || !release.prerelease)
                    }
                    
                    guard let latestRelease = validReleases.first else {
                        Self.logger.info("No valid releases found")
                        completion(.failure(.noReleasesFound))
                        return
                    }
                    
                    Self.logger.info("Found release: \(latestRelease.tagName)")
                    completion(.success(latestRelease))
                    
                } catch {
                    Self.logger.error("JSON parsing error: \(error.localizedDescription)")
                    completion(.failure(.invalidResponse))
                }
            }
        }.resume()
    }
    
    private func parseRelease(_ release: GitHubRelease) -> UpdateInfo? {
        // Look for a .zip asset that matches our app
        // Expected naming: Whispered.zip or Whispered-1.2.3.zip
        let zipAsset = release.assets.first { asset in
            let name = asset.name.lowercased()
            return name.contains("whispered") && name.hasSuffix(".zip")
        }
        
        // Fallback: any .zip file
        let fallbackAsset = release.assets.first { $0.name.hasSuffix(".zip") }
        
        guard let asset = zipAsset ?? fallbackAsset,
              let downloadURL = URL(string: asset.browserDownloadUrl) else {
            return nil
        }
        
        // Parse published date
        var publishedDate: Date? = nil
        if let dateString = release.publishedAt {
            let formatter = ISO8601DateFormatter()
            publishedDate = formatter.date(from: dateString)
        }
        
        return UpdateInfo(
            version: release.tagName,
            releaseNotes: release.body,
            downloadURL: downloadURL,
            fileSize: asset.size,
            publishedAt: publishedDate
        )
    }
    
    private func extractAndInstall(
        from zipURL: URL,
        progress: @escaping (UpdateProgress) -> Void,
        completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        progress(UpdateProgress(phase: .extracting, progress: 0.5, bytesDownloaded: 0, totalBytes: 0))

        // Exécuter l'extraction sur une background queue pour ne pas bloquer l'UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Create temp directory for extraction
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(.extractionFailed(error.localizedDescription)))
                }
                return
            }

            // Unzip using ditto (macOS built-in, handles .app bundles correctly)
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzipProcess.arguments = ["-xk", zipURL.path, tempDir.path]

            do {
                try unzipProcess.run()
                unzipProcess.waitUntilExit()  // Bloque cette background queue, pas le main thread

                // Nettoyer le fichier zip temporaire
                try? FileManager.default.removeItem(at: zipURL)

                if unzipProcess.terminationStatus != 0 {
                    try? FileManager.default.removeItem(at: tempDir)
                    DispatchQueue.main.async {
                        completion(.failure(.extractionFailed("ditto exit code: \(unzipProcess.terminationStatus)")))
                    }
                    return
                }
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                try? FileManager.default.removeItem(at: zipURL)
                DispatchQueue.main.async {
                    completion(.failure(.extractionFailed(error.localizedDescription)))
                }
                return
            }

            // Find the .app in the extracted contents
            guard let appBundle = self.findAppBundle(in: tempDir) else {
                try? FileManager.default.removeItem(at: tempDir)
                DispatchQueue.main.async {
                    completion(.failure(.extractionFailed("No .app bundle found in archive")))
                }
                return
            }

            Self.logger.info("Extracted app: \(appBundle.lastPathComponent)")

            // Install the app (retour sur main thread)
            DispatchQueue.main.async {
                self.installApp(from: appBundle, tempDir: tempDir, progress: progress, completion: completion)
            }
        }
    }
    
    private func findAppBundle(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        
        // First, check direct children
        if let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for item in contents {
                if item.pathExtension == "app" {
                    return item
                }
            }
            
            // Check one level deeper (some zips have a folder containing the app)
            for item in contents {
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    if let subContents = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                        for subItem in subContents {
                            if subItem.pathExtension == "app" {
                                return subItem
                            }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func installApp(
        from newAppURL: URL,
        tempDir: URL,
        progress: @escaping (UpdateProgress) -> Void,
        completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        progress(UpdateProgress(phase: .installing, progress: 0.8, bytesDownloaded: 0, totalBytes: 0))
        
        // Get the current app's location
        let currentAppURL = Bundle.main.bundleURL
        let applicationsDir = URL(fileURLWithPath: "/Applications")
        
        // Determine target location
        // If running from /Applications, update in place
        // Otherwise, install to /Applications
        let targetURL: URL
        if currentAppURL.path.hasPrefix("/Applications") {
            targetURL = currentAppURL
        } else {
            targetURL = applicationsDir.appendingPathComponent("Whispered.app")
        }
        
        Self.logger.info("Installing to: \(targetURL.path)")
        
        // Check if we can write to the target location
        let fileManager = FileManager.default
        let canWrite = fileManager.isWritableFile(atPath: targetURL.deletingLastPathComponent().path)
        
        if canWrite {
            // Direct installation (no admin needed)
            performDirectInstall(from: newAppURL, to: targetURL, tempDir: tempDir, progress: progress, completion: completion)
        } else {
            // Need admin privileges - use AppleScript authorization
            performAuthorizedInstall(from: newAppURL, to: targetURL, tempDir: tempDir, progress: progress, completion: completion)
        }
    }
    
    private func performDirectInstall(
        from newAppURL: URL,
        to targetURL: URL,
        tempDir: URL,
        progress: @escaping (UpdateProgress) -> Void,
        completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        let fileManager = FileManager.default
        
        do {
            // Create backup of existing app
            let backupURL = targetURL.deletingLastPathComponent()
                .appendingPathComponent("\(targetURL.deletingPathExtension().lastPathComponent)_backup.app")
            
            // Remove any existing backup
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            
            // Move current app to backup
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.moveItem(at: targetURL, to: backupURL)
            }
            
            // Copy new app to target
            do {
                try fileManager.copyItem(at: newAppURL, to: targetURL)
                
                // Success - remove backup and temp files
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.removeItem(at: tempDir)
                
                Self.logger.info("Installation successful")
                
                // Restart the app
                restartApp(progress: progress, completion: completion)
                
            } catch {
                // Restore backup on failure
                Self.logger.error("Installation failed, restoring backup")
                try? fileManager.removeItem(at: targetURL)
                try? fileManager.moveItem(at: backupURL, to: targetURL)
                try? fileManager.removeItem(at: tempDir)
                
                completion(.failure(.installationFailed(error.localizedDescription)))
            }
            
        } catch {
            try? fileManager.removeItem(at: tempDir)
            completion(.failure(.installationFailed(error.localizedDescription)))
        }
    }
    
    /// Échappe un path pour utilisation dans un shell script single-quoted
    private func shellEscape(_ path: String) -> String {
        // Dans un string single-quoted en shell, seul ' doit être échappé
        // On ferme le single quote, on ajoute un single quote échappé, on rouvre
        return path.replacingOccurrences(of: "'", with: "'\"'\"'")
    }

    private func performAuthorizedInstall(
        from newAppURL: URL,
        to targetURL: URL,
        tempDir: URL,
        progress: @escaping (UpdateProgress) -> Void,
        completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        // Use AppleScript to request admin privileges
        // This shows the standard macOS authorization dialog

        let backupPath = targetURL.deletingLastPathComponent()
            .appendingPathComponent("\(targetURL.deletingPathExtension().lastPathComponent)_backup.app").path

        // Échapper tous les paths pour éviter l'injection de commandes
        let escapedBackupPath = shellEscape(backupPath)
        let escapedTargetPath = shellEscape(targetURL.path)
        let escapedNewAppPath = shellEscape(newAppURL.path)

        let script = """
        do shell script "
            # Remove existing backup
            rm -rf '\(escapedBackupPath)' 2>/dev/null || true

            # Backup current app if exists
            if [ -d '\(escapedTargetPath)' ]; then
                mv '\(escapedTargetPath)' '\(escapedBackupPath)'
            fi

            # Copy new app
            cp -R '\(escapedNewAppPath)' '\(escapedTargetPath)'

            # Set permissions
            chmod -R 755 '\(escapedTargetPath)'

            # Remove backup on success
            rm -rf '\(escapedBackupPath)' 2>/dev/null || true
        " with administrator privileges
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            
            if let error = error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                Self.logger.error("Authorized install failed: \(message)")
                
                // Clean up
                try? FileManager.default.removeItem(at: tempDir)
                
                // If user cancelled, return cancelled error
                if message.contains("cancel") || (error[NSAppleScript.errorNumber] as? Int) == -128 {
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.installationFailed(message)))
                }
                return
            }
            
            // Clean up temp files
            try? FileManager.default.removeItem(at: tempDir)
            
            Self.logger.info("Authorized installation successful")
            
            // Restart the app
            restartApp(progress: progress, completion: completion)
            
        } else {
            try? FileManager.default.removeItem(at: tempDir)
            completion(.failure(.installationFailed("Could not create AppleScript")))
        }
    }
    
    private func restartApp(
        progress: @escaping (UpdateProgress) -> Void,
        completion: @escaping (Result<Void, UpdateError>) -> Void
    ) {
        progress(UpdateProgress(phase: .restarting, progress: 1.0, bytesDownloaded: 0, totalBytes: 0))

        // Path to the installed app
        let installedAppPath: String
        if Bundle.main.bundlePath.hasPrefix("/Applications") {
            installedAppPath = Bundle.main.bundlePath
        } else {
            installedAppPath = "/Applications/Whispered.app"
        }

        Self.logger.info("Restarting app from: \(installedAppPath)")

        // Créer un script temporaire qui survit à la fermeture de l'app
        let tempScript = FileManager.default.temporaryDirectory.appendingPathComponent("whispered_restart.sh")
        let scriptContent = """
        #!/bin/bash
        sleep 2
        open "\(installedAppPath)"
        rm -f "\(tempScript.path)"
        """

        do {
            try scriptContent.write(to: tempScript, atomically: true, encoding: .utf8)

            // Rendre le script exécutable et le lancer avec nohup
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "chmod +x '\(tempScript.path)' && nohup '\(tempScript.path)' >/dev/null 2>&1 &"]

            try process.run()
        } catch {
            Self.logger.error("Failed to schedule restart: \(error.localizedDescription)")
        }

        completion(.success(()))

        // Terminer l'app actuelle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateService: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        
        progressHandler?(UpdateProgress(
            phase: .downloading,
            progress: progress,
            bytesDownloaded: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        ))
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // This is handled by the completion handler, not the delegate
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, !isCancelled {
            Self.logger.error("Download task error: \(error.localizedDescription)")
        }
    }
}
