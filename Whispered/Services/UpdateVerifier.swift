import CryptoKit
import Foundation
import Security
import os.log

/// Vérifie qu'une mise à jour téléchargée est bien celle publiée.
///
/// Avant, le zip récupéré depuis GitHub était dézippé puis copié dans
/// `/Applications` sans aucun contrôle : n'importe quelle archive servie à la
/// place de la bonne devenait du code exécuté. Deux garde-fous ici :
/// l'empreinte SHA-256 annoncée par l'API GitHub, et la validité de la
/// signature du bundle extrait comparée à celle de l'app en cours.
enum UpdateVerifier {
    private static let logger = Logger(subsystem: "com.whispered", category: "UpdateVerifier")

    /// `kSecCodeSignatureAdhoc` de CSCommon.h, non exposé à Swift.
    private static let adhocSignatureFlag: UInt32 = 0x0000_0002

    enum VerificationError: LocalizedError {
        case digestMismatch(expected: String, actual: String)
        case unreadableFile(String)
        case signatureInvalid(String)
        case identityMismatch(expected: String, actual: String)
        /// Ni signature exploitable, ni empreinte publiée
        case unverifiable

        var errorDescription: String? {
            switch self {
            case .digestMismatch(let expected, let actual):
                return "L'empreinte de l'archive ne correspond pas (attendu \(expected.prefix(12))…, obtenu \(actual.prefix(12))…)."
            case .unreadableFile(let detail):
                return "Archive illisible : \(detail)"
            case .signatureInvalid(let detail):
                return "Signature de l'application invalide : \(detail)"
            case .identityMismatch(let expected, let actual):
                return "La mise à jour est signée par « \(actual) » au lieu de « \(expected) »."
            case .unverifiable:
                return "Origine invérifiable : cette application est signée ad-hoc et la release ne publie pas d'empreinte. Mets à jour depuis les sources."
            }
        }
    }

    // MARK: - Empreinte de l'archive

    /// SHA-256 calculé par blocs : une archive de 10 Mo n'a pas à passer en mémoire.
    static func sha256(of fileURL: URL) throws -> String {
        guard let stream = InputStream(url: fileURL) else {
            throw VerificationError.unreadableFile(fileURL.lastPathComponent)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1 << 16
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 {
                throw VerificationError.unreadableFile(stream.streamError?.localizedDescription ?? "lecture interrompue")
            }
            if read == 0 { break }
            hasher.update(data: Data(buffer[0..<read]))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compare l'empreinte du fichier à celle annoncée par GitHub.
    /// Accepte les formes « sha256:abc… » et « abc… ».
    /// Si GitHub ne fournit pas d'empreinte, on ne bloque pas la mise à jour :
    /// la vérification de signature reste le second filet.
    static func verifyDigest(_ expected: String?, of fileURL: URL) throws {
        guard let expected, !expected.isEmpty else {
            logger.notice("Aucune empreinte publiée pour cette release, contrôle ignoré")
            return
        }
        let normalized = expected
            .replacingOccurrences(of: "sha256:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let actual = try sha256(of: fileURL)
        guard actual == normalized else {
            throw VerificationError.digestMismatch(expected: normalized, actual: actual)
        }
        logger.info("Empreinte de l'archive vérifiée")
    }

    // MARK: - Signature du bundle

    struct Identity: Equatable {
        /// Identifiant d'équipe Apple, nil pour une signature ad-hoc
        let teamID: String?
        /// Nom du certificat, nil pour une signature ad-hoc
        let commonName: String?
        let isAdHoc: Bool

        var describedName: String {
            if isAdHoc { return "signature ad-hoc" }
            if let commonName { return commonName }
            if let teamID { return "équipe \(teamID)" }
            return "signature inconnue"
        }
    }

    /// Vérifie que le bundle est signé, que sa signature est cohérente avec son
    /// contenu, et qu'il provient du même signataire que l'app en cours.
    static func verifySignature(
        of appURL: URL,
        againstRunningApp runningAppURL: URL = Bundle.main.bundleURL,
        hasPublishedDigest: Bool = true
    ) throws {
        let newIdentity = try identity(of: appURL, checkValidity: true)
        let currentIdentity = try? identity(of: runningAppURL, checkValidity: false)

        guard let currentIdentity else {
            // App en cours non signée ou illisible : on s'en tient à la validité
            // de la nouvelle signature, qu'on vient de contrôler.
            logger.notice("Signature de l'app en cours indéterminée, comparaison ignorée")
            return
        }

        // Une signature ad-hoc ne prouve rien : elle est auto-cohérente par
        // construction, donc n'importe quel bundle la produit. Si en plus la
        // release ne publie pas d'empreinte, il ne reste aucun moyen de
        // distinguer une mise à jour légitime d'une autre : on refuse.
        if currentIdentity.isAdHoc {
            guard newIdentity.isAdHoc else {
                throw VerificationError.identityMismatch(
                    expected: currentIdentity.describedName,
                    actual: newIdentity.describedName
                )
            }
            guard hasPublishedDigest else {
                throw VerificationError.unverifiable
            }
            logger.notice("Signature ad-hoc des deux côtés : seule l'empreinte publiée garantit l'origine")
            return
        }

        guard newIdentity.teamID == currentIdentity.teamID else {
            throw VerificationError.identityMismatch(
                expected: currentIdentity.describedName,
                actual: newIdentity.describedName
            )
        }
        logger.info("Signataire identique à l'app en cours : \(newIdentity.describedName, privacy: .public)")
    }

    /// Lit l'identité de signature d'un bundle, et vérifie au passage que le
    /// contenu n'a pas été modifié après signature si `checkValidity` est vrai.
    static func identity(of bundleURL: URL, checkValidity: Bool) throws -> Identity {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw VerificationError.signatureInvalid("bundle non signé (code \(createStatus))")
        }

        if checkValidity {
            let validity = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: 0), nil)
            guard validity == errSecSuccess else {
                throw VerificationError.signatureInvalid("contenu modifié après signature (code \(validity))")
            }
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard infoStatus == errSecSuccess,
              let dict = info as? [String: Any] else {
            throw VerificationError.signatureInvalid("informations de signature illisibles")
        }

        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = dict[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let isAdHoc = (flags & Self.adhocSignatureFlag) != 0

        var commonName: String?
        if let chain = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = chain.first {
            var name: CFString?
            if SecCertificateCopyCommonName(leaf, &name) == errSecSuccess {
                commonName = name as String?
            }
        }

        return Identity(teamID: teamID, commonName: commonName, isAdHoc: isAdHoc)
    }
}
