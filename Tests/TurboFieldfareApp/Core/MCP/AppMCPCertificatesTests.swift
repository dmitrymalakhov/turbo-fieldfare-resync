#if os(macOS)
import Foundation
import Testing
@testable import TurboFieldfareAppCore

struct AppMCPCertificatesTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TURBOFIELDFARE_TEST_CA_BUNDLE"] != nil))
    func explicitlySelectedLocalBundleImportsWithoutNetwork() throws {
        let path = try #require(ProcessInfo.processInfo.environment["TURBOFIELDFARE_TEST_CA_BUNDLE"])
        let selection = try AppMCPCertificates.readFile(URL(fileURLWithPath: path))
        #expect(!selection.certificates.isEmpty)
        try AppMCPCertificates.validate(AppMCPCertificates.inspect(selection))
    }

    @Test func bundleSkipsDateInvalidRootsAndRejectsAllExpiredFile() throws {
        let root = try AppMCPCertificate(der: MCPCertificateFixtures.root)
        let expired = try AppMCPCertificate(der: MCPCertificateFixtures.expired)
        let future = try AppMCPCertificate(der: MCPCertificateFixtures.future)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ca-bundle-\(UUID()).pem")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((root.pem + expired.pem + future.pem).utf8).write(to: file)
        let selection = try AppMCPCertificates.readFile(file)
        #expect(selection.certificates == [root.der])
        #expect(selection.skippedDateInvalidCount == 2)
        #expect(try JSONDecoder().decode(AppMCPCertificateSelection.self, from: JSONEncoder().encode(selection)) == selection)
        try Data(expired.pem.utf8).write(to: file)
        #expect(throws: (any Error).self) { try AppMCPCertificates.readFile(file) }
        #expect(try AppMCPCertificates.decode(Data(String(repeating: root.pem, count: 129).utf8)).count == 129)
        #expect(throws: (any Error).self) {
            try AppMCPCertificates.decode(Data(String(repeating: root.pem, count: 513).utf8))
        }
    }

    @Test func certificateParsingPreservesIdentityAndRejectsExpiredFutureAndOrdinaryLeafCertificates() throws {
        let root = try AppMCPCertificate(der: MCPCertificateFixtures.root)
        #expect(root.name == "Example Corporate CA root")
        #expect(root.issuer == root.name)
        #expect(root.isCertificateAuthority)
        #expect(root.isSelfIssued && root.isSelfSigned)
        #expect(root.validityIssue == nil)
        #expect(root.fingerprint.split(separator: ":").count == 32)
        #expect(try AppMCPCertificates.decode(Data(root.pem.utf8)) == [root])
        let decoded = try AppMCPCertificates.decode(Data((root.pem + root.pem).utf8))
        #expect(decoded == [root, root])
        for data in [MCPCertificateFixtures.expired, MCPCertificateFixtures.future, MCPServerCertificateFixtures.server] {
            let certificate = try AppMCPCertificate(der: data)
            #expect(certificate.validityIssue != nil)
            #expect(throws: (any Error).self) { try AppMCPCertificates.validate([certificate]) }
        }
        let selfSigned = try AppMCPCertificate(der: MCPCertificateFixtures.leaf)
        #expect(selfSigned.isSelfSigned && !selfSigned.isCertificateAuthority)
        #expect(selfSigned.validityIssue == nil)
        let forged = try AppMCPCertificate(der: MCPServerCertificateFixtures.forgedSelfIssued)
        #expect(forged.isSelfIssued && !forged.isSelfSigned)
        #expect(forged.validityIssue != nil)
    }

    @Test func importRejectsPrivateKeysMalformedPEMAndOversizedFiles() throws {
        let root = try AppMCPCertificate(der: MCPCertificateFixtures.root)
        let malformed = ["", "not a certificate", root.pem + "-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----",
                         root.pem + "-----BEGIN CERTIFICATE-----\ninvalid",
                         "# comment\n" + root.pem + "-----BEGIN RSA PRIVATE KEY-----\nYWJj\n-----END RSA PRIVATE KEY-----",
                         root.pem + "-----END CERTIFICATE-----"]
        for text in malformed {
            #expect(throws: (any Error).self) { try AppMCPCertificates.decode(Data(text.utf8)) }
        }
        #expect(throws: (any Error).self) {
            try AppMCPCertificates.decode(Data(repeating: 0, count: AppMCPCertificates.maximumFileSize + 1))
        }
        #expect(throws: (any Error).self) {
            try AppMCPCertificates.inspect(.init(certificates: [], source: "invalid"))
        }
    }

    @Test func systemPEMDescriptionsAreIgnoredAndNeverPersisted() throws {
        let root = try AppMCPCertificate(der: MCPCertificateFixtures.root)
        let text = "# OpenBSD CA bundle\n=== /CN=Example CA\nCertificate:\n    Data:\n        Version: 3 (0x2)\n"
        let data = Data((text + root.pem + "\n# Another certificate\n" + root.pem + "\nEnd of bundle\n").utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pem-descriptions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cert.pem")
        try data.write(to: file)
        var profile = AppMCPProfile()
        profile.selectedCertificates = try AppMCPCertificates.readFile(file)
        #expect(profile.selectedCertificates?.certificates == [root.der, root.der])
        let prepared = try #require(try AppMCPCertificates.prepare(profile: profile, directory: directory))
        #expect(try String(contentsOf: prepared, encoding: .utf8) == root.pem + root.pem)
    }

    @Test func selectedCertificatesAreCopiedAndScopedPerConnectionWithLegacyFileSupport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-certificates-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("corporate.cer")
        try MCPCertificateFixtures.root.write(to: file)
        let selection = try AppMCPCertificates.readFile(file)
        #expect(selection.source == "corporate.cer")
        let first = AppMCPProfile()
        #expect(try AppMCPCertificates.prepare(profile: first, directory: directory) == nil)
        var second = AppMCPProfile(); second.selectedCertificates = selection
        try FileManager.default.removeItem(at: file)
        let bundle = try #require(try AppMCPCertificates.prepare(profile: second, directory: directory))
        #expect(bundle.lastPathComponent == second.id.uuidString + ".pem")
        #expect(try AppMCPCertificates.decode(Data(contentsOf: bundle)).map(\.der) == [MCPCertificateFixtures.root])
        #expect(try FileManager.default.attributesOfItem(atPath: bundle.path)[.posixPermissions] as? Int == 0o600)
        var legacy = AppMCPProfile(); legacy.certificateBundle = bundle.path
        let legacyBundle = try #require(try AppMCPCertificates.prepare(profile: legacy, directory: directory))
        #expect(legacyBundle != bundle)
        #expect(try Data(contentsOf: bundle) == Data(contentsOf: legacyBundle))
        legacy.certificateBundle = directory.appendingPathComponent("missing.pem").path
        #expect(throws: (any Error).self) { try AppMCPCertificates.prepare(profile: legacy, directory: directory) }
    }

    @Test func legacyProfilesDecodeWithoutCertificateSelection() throws {
        let profile = AppMCPProfile()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "selectedCertificates")
        let decoded = try JSONDecoder().decode(AppMCPProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.selectedCertificates == nil)
        #expect(decoded == profile)
    }
}
#endif
