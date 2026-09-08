#if os(macOS)
import Foundation
import Security
import Testing
@testable import TurboFieldfareAppCore

struct AppMCPServerCertificatesTests {
    private let date = Date(timeIntervalSince1970: 1_788_566_400) // 2026-09-05 UTC

    @Test func matchesCryptographicChainAndReturnsItsIntermediatesWithoutTrustingNames() throws {
        let root = try AppMCPCertificate(der: MCPServerCertificateFixtures.root)
        let unrelated = try AppMCPCertificate(der: MCPServerCertificateFixtures.lookalikeRoot)
        #expect(root.name == unrelated.name && root.id != unrelated.id)
        let result = try AppMCPServerCertificates.match(host: "mail.example.invalid",
            serverChain: [MCPServerCertificateFixtures.server, MCPServerCertificateFixtures.intermediate],
            candidates: [unrelated, root], date: date)
        #expect(result.matchingIDs == [root.id])
        #expect(result.suggestedChain.map(\.der) == [MCPServerCertificateFixtures.intermediate, root.der])
    }

    @Test func wrongHostnameExpiredServerAndUnknownCAHaveNoSuggestions() throws {
        let root = try AppMCPCertificate(der: MCPServerCertificateFixtures.root)
        for (host, leaf, candidates) in [
            ("wrong.example.invalid", MCPServerCertificateFixtures.server, [root]),
            ("mail.example.invalid", MCPServerCertificateFixtures.expiredServer, [root]),
            ("mail.example.invalid", MCPServerCertificateFixtures.server, [])
        ] {
            let result = try AppMCPServerCertificates.match(host: host,
                serverChain: [leaf, MCPServerCertificateFixtures.intermediate], candidates: candidates, date: date)
            #expect(result.matchingIDs.isEmpty && result.suggestedChain.isEmpty)
        }
    }

    @Test func selfSignedServerMatchesOnlyWhenAlreadyAnExplicitCandidate() throws {
        let server = try AppMCPCertificate(der: MCPServerCertificateFixtures.selfSignedServer)
        #expect(server.isSelfSigned && !server.isCertificateAuthority)
        let known = try AppMCPServerCertificates.match(host: "mail.example.invalid", serverChain: [server.der],
                                                       candidates: [server], date: date)
        #expect(known.matchingIDs == [server.id] && known.suggestedChain == [server])
        let unknown = try AppMCPServerCertificates.match(host: "mail.example.invalid", serverChain: [server.der],
                                                         candidates: [], date: date)
        #expect(unknown.suggestedChain.isEmpty)
    }

    @Test func certificateInspectionDisablesIssuerAndRevocationNetworkFetches() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, MCPServerCertificateFixtures.server as CFData))
        var value: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, nil, &value) == errSecSuccess)
        let trust = try #require(value)
        try AppMCPServerCertificates.configureOfflineTrust(trust, host: "mail.example.invalid")
        var allowed = DarwinBoolean(true)
        #expect(SecTrustGetNetworkFetchAllowed(trust, &allowed) == errSecSuccess)
        #expect(!allowed.boolValue)
        var policies: CFArray?
        #expect(SecTrustCopyPolicies(trust, &policies) == errSecSuccess)
        #expect((policies as? [SecPolicy])?.count == 2)
    }

    @Test func serverProbeRejectsURLsUserInfoPortsAndPaths() throws {
        #expect(try AppMCPServerCertificates.normalizedHost(" Mail.Example.Invalid ") == "mail.example.invalid")
        #expect(try AppMCPServerCertificates.normalizedHost("127.0.0.1") == "127.0.0.1")
        for host in ["", "https://mail.example.com", "mail.example.com:443", "user@mail.example.com", "mail.example.com/path", "mail.example.com?x", "mail..example.com"] {
            #expect(throws: (any Error).self) { try AppMCPServerCertificates.normalizedHost(host) }
        }
    }

    @Test func cancellationBeforeProbeDoesNotLeaveAConnectionWaiting() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppMCPTLSCertificateProbe().fetch(host: "127.0.0.1", port: 1)
        }
        do { _ = try await task.value; Issue.record("Cancelled probe unexpectedly succeeded") }
        catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
    }
}
#endif
