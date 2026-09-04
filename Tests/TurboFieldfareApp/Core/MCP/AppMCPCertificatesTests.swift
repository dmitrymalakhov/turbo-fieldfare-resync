#if os(macOS)
import Foundation
import Testing
@testable import TurboFieldfareAppCore

struct AppMCPCertificatesTests {
    @Test func certificateParsingPreservesIdentityAndRejectsExpiredFutureAndLeafCertificates() throws {
        let root = try AppMCPCertificate(der: MCPCertificateFixtures.root)
        #expect(root.name == "Example Corporate CA root")
        #expect(root.issuer == root.name)
        #expect(root.isCertificateAuthority)
        #expect(root.validityIssue == nil)
        #expect(root.fingerprint.split(separator: ":").count == 32)
        #expect(try AppMCPCertificates.decode(Data(root.pem.utf8)) == [root])
        let decoded = try AppMCPCertificates.decode(Data((root.pem + root.pem).utf8))
        #expect(decoded == [root, root])
        for data in [MCPCertificateFixtures.expired, MCPCertificateFixtures.future, MCPCertificateFixtures.leaf] {
            let certificate = try AppMCPCertificate(der: data)
            #expect(certificate.validityIssue != nil)
            #expect(throws: (any Error).self) { try AppMCPCertificates.validate([certificate]) }
        }
    }

    @Test func importRejectsPrivateKeysMalformedPEMAndOversizedFiles() throws {
        let root = try AppMCPCertificate(der: MCPCertificateFixtures.root)
        let malformed = ["", "not a certificate", root.pem + "-----BEGIN PRIVATE KEY-----\nYWJj\n-----END PRIVATE KEY-----",
                         root.pem + "-----BEGIN CERTIFICATE-----\ninvalid", root.pem + "unexpected data"]
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
