import Foundation

public struct AppMCPCertificateSelection: Codable, Equatable, Sendable {
    public let certificates: [Data]
    public let source: String

    public init(certificates: [Data], source: String) {
        self.certificates = certificates; self.source = source
    }
}

#if os(macOS)
import CryptoKit
import Security

public struct AppMCPCertificate: Identifiable, Equatable, Sendable {
    public let der: Data
    public let name: String
    public let issuer: String
    public let notBefore: Date
    public let notAfter: Date
    public let isCertificateAuthority: Bool
    public let isSelfIssued: Bool
    public let isSelfSigned: Bool
    public let fingerprint: String
    public var id: String { fingerprint }
    public var validityIssue: String? { validityIssue(at: Date()) }

    func validityIssue(at date: Date) -> String? {
        if date < notBefore { return "This certificate is not valid yet." }
        if date > notAfter { return "This certificate has expired. Choose its replacement." }
        if !isCertificateAuthority && !isSelfSigned { return "This server or personal certificate needs its issuing CA. Choose a CA or a self-signed server certificate." }
        return nil
    }

    init(der: Data) throws {
        guard der.count <= AppMCPCertificates.maximumFileSize,
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(certificate,
                [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore,
                 kSecOIDX509V1ValidityNotAfter, kSecOIDBasicConstraints] as CFArray, nil) as? [String: [String: Any]],
              let start = values[kSecOIDX509V1ValidityNotBefore as String]?[kSecPropertyKeyValue as String] as? NSNumber,
              let end = values[kSecOIDX509V1ValidityNotAfter as String]?[kSecPropertyKeyValue as String] as? NSNumber else {
            throw AppMCPError.configuration("The file does not contain a readable X.509 certificate. Choose a PEM, CER, CRT or DER certificate without a private key.")
        }
        self.der = SecCertificateCopyData(certificate) as Data
        if let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate),
           let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) {
            isSelfIssued = issuer == subject
        } else { isSelfIssued = false }
        isSelfSigned = isSelfIssued && AppMCPCertificateSignature.isSelfSigned(certificate, der: self.der)
        name = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed certificate"
        let issuerValues = values[kSecOIDX509V1IssuerName as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        issuer = issuerValues.first { $0[kSecPropertyKeyLabel as String] as? String == "2.5.4.3" }?[kSecPropertyKeyValue as String] as? String
            ?? issuerValues.compactMap { $0[kSecPropertyKeyValue as String] as? String }.joined(separator: ", ")
        notBefore = Date(timeIntervalSinceReferenceDate: start.doubleValue)
        notAfter = Date(timeIntervalSinceReferenceDate: end.doubleValue)
        // Use Security's non-localized property label, not its localized display label.
        let constraints = values[kSecOIDBasicConstraints as String]?[kSecPropertyKeyValue as String] as? [[String: Any]] ?? []
        isCertificateAuthority = constraints.contains {
            $0[kSecPropertyKeyLabel as String] as? String == "Certificate Authority"
                && $0[kSecPropertyKeyValue as String] as? String == "Yes"
        }
        fingerprint = SHA256.hash(data: self.der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    var pem: String {
        let encoded = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(encoded)\n-----END CERTIFICATE-----\n"
    }

    public var kindDescription: String {
        let type = isCertificateAuthority ? "CA certificate" : "Server / personal certificate"
        if isSelfSigned { return "Self-signed · " + type }
        if isSelfIssued { return "Self-issued · " + type }
        return type
    }
}

/// Certificate-only, local operations. No identity/private-key queries, trust changes,
/// network requests or SecTrust evaluation (which can fetch issuers/OCSP).
public enum AppMCPCertificates {
    static let maximumFileSize = 1_048_576

    public static func inKeychain() throws -> [AppMCPCertificate] {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecItemNotFound { try check(status) }
        var all = result as? [SecCertificate] ?? []
        // Include managed and system roots even if their keychain is not on the search list.
        for domain: SecTrustSettingsDomain in [.user, .admin, .system] {
            var certificates: CFArray?
            let status = SecTrustSettingsCopyCertificates(domain, &certificates)
            if status == errSecNoTrustSettings || status == errSecItemNotFound { continue }
            try check(status)
            all.append(contentsOf: certificates as? [SecCertificate] ?? [])
        }
        let certificates = all.compactMap {
            try? AppMCPCertificate(der: SecCertificateCopyData($0) as Data)
        }
        var seen = Set<String>()
        return certificates.filter { seen.insert($0.id).inserted }.sorted {
            if ($0.validityIssue == nil) != ($1.validityIssue == nil) { return $0.validityIssue == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            throw AppMCPError.configuration("Could not read certificates from Keychain (\(status)): \(message)")
        }
    }

    public static func readFile(_ url: URL) throws -> AppMCPCertificateSelection {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw AppMCPError.configuration("Choose a certificate file, not a folder or special file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumFileSize + 1) ?? Data()
        let certificates = try decode(data)
        try validate(certificates)
        return .init(certificates: certificates.map(\.der), source: url.lastPathComponent)
    }

    static func decode(_ data: Data) throws -> [AppMCPCertificate] {
        guard !data.isEmpty, data.count <= maximumFileSize else {
            throw AppMCPError.configuration("The certificate file is empty or larger than 1 MB.")
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else {
            return [try AppMCPCertificate(der: data)]
        }
        // Accept certificate blocks only. Never retain a private key accidentally included in a PEM.
        let pattern = "-----BEGIN CERTIFICATE-----\\s*([A-Za-z0-9+/=\\s]+?)\\s*-----END CERTIFICATE-----"
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        let remainder = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        guard !matches.isEmpty, matches.count <= 128,
              remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppMCPError.configuration("Choose a PEM containing only certificates. Private keys, identities and other PEM blocks are not accepted.")
        }
        return try matches.map { match in
            let body = String(text[Range(match.range(at: 1), in: text)!]).filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: body) else { throw AppMCPError.configuration("Invalid PEM certificate encoding.") }
            return try AppMCPCertificate(der: der)
        }
    }

    public static func inspect(_ selection: AppMCPCertificateSelection) throws -> [AppMCPCertificate] {
        guard !selection.certificates.isEmpty, selection.certificates.count <= 128,
              selection.certificates.reduce(0, { $0 + $1.count }) <= maximumFileSize else {
            throw AppMCPError.configuration("Choose between 1 and 128 certificates, at most 1 MB in total.")
        }
        return try selection.certificates.map { try AppMCPCertificate(der: $0) }
    }

    static func validate(_ certificates: [AppMCPCertificate]) throws {
        for certificate in certificates {
            if let issue = certificate.validityIssue {
                throw AppMCPError.configuration("\(certificate.name): \(issue)")
            }
        }
    }

    static func prepare(profile: AppMCPProfile, directory: URL) throws -> URL? {
        let certificates: [AppMCPCertificate]
        if let selection = profile.selectedCertificates {
            certificates = try inspect(selection)
        } else if !profile.certificateBundle.isEmpty {
            let path = (profile.certificateBundle as NSString).expandingTildeInPath
            certificates = try inspect(readFile(URL(fileURLWithPath: path)))
        } else { return nil }
        try validate(certificates)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(profile.id.uuidString + ".pem")
        try Data(certificates.map(\.pem).joined().utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
#endif
