#if os(macOS)
import Foundation
import Network
import Security

public struct AppMCPCertificateSuggestion: Sendable {
    public let host: String
    public let serverCertificate: AppMCPCertificate
    public let matchingIDs: Set<String>
    /// A complete locally verified path, anchored in a candidate the user already has.
    public let suggestedChain: [AppMCPCertificate]
    public let explanation: String
}

public enum AppMCPServerCertificates {
    public static func normalizedHost(_ value: String) throws -> String {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw AppMCPError.configuration("Enter the Exchange hostname in Connection first, without a URL, port or path.") }
        return host
    }

    /// Explicit TLS-only probe of the configured host. No HTTP, authentication or mail.
    public static func find(host: String, candidates: [AppMCPCertificate]) async throws -> AppMCPCertificateSuggestion {
        let host = try normalizedHost(host)
        let chain = try await AppMCPTLSCertificateProbe().fetch(host: host)
        let task = Task.detached(priority: .userInitiated) {
            try match(host: host, serverChain: chain, candidates: candidates)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func match(host: String, serverChain: [Data], candidates: [AppMCPCertificate], date: Date = Date()) throws -> AppMCPCertificateSuggestion {
        let host = try normalizedHost(host)
        guard !serverChain.isEmpty, serverChain.count <= 16,
              serverChain.reduce(0, { $0 + $1.count }) <= AppMCPCertificates.maximumFileSize else {
            throw AppMCPError.configuration("The server returned an empty or oversized certificate chain.")
        }
        let peer = try AppMCPCertificate(der: serverChain[0])
        let chain = try serverChain.map { data -> SecCertificate in
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw AppMCPError.configuration("The server returned an unreadable certificate.")
            }
            return certificate
        }
        var matching = Set<String>(), suggested: [AppMCPCertificate] = []
        // Prefer a full path to a root over trusting an intermediate on its own.
        let ordered = candidates.sorted {
            if $0.isSelfSigned != $1.isSelfSigned { return $0.isSelfSigned }
            return $0.fingerprint < $1.fingerprint
        }
        let deadline = ContinuousClock.now + .seconds(10)
        for candidate in ordered {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw AppMCPError.configuration("Local certificate verification took too long. Retry or choose your corporate certificate manually.") }
            guard candidate.validityIssue(at: date) == nil,
                  let anchor = SecCertificateCreateWithData(nil, candidate.der as CFData) else { continue }
            var value: SecTrust?
            try check(SecTrustCreateWithCertificates(chain as CFArray, nil, &value))
            guard let trust = value else { throw AppMCPError.protocolError }
            try configureOfflineTrust(trust, host: host)
            try check(SecTrustSetVerifyDate(trust, date as CFDate))
            try check(SecTrustSetAnchorCertificates(trust, [anchor] as CFArray))
            try check(SecTrustSetAnchorCertificatesOnly(trust, true))
            guard SecTrustEvaluateWithError(trust, nil), peer.notBefore <= date, peer.notAfter >= date,
                  let verified = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let last = verified.last, SecCertificateCopyData(last) as Data == candidate.der else { continue }
            let path = try verified.map { try AppMCPCertificate(der: SecCertificateCopyData($0) as Data) }
            // A self-signed server is its own anchor. Otherwise export only its issuing chain.
            let issuers = path.count == 1 ? path : Array(path.dropFirst())
            guard !issuers.isEmpty, issuers.allSatisfy({ $0.validityIssue(at: date) == nil }) else { continue }
            matching.insert(candidate.id)
            if suggested.isEmpty { suggested = issuers }
        }
        let explanation: String
        if !matching.isEmpty {
            explanation = "A certificate path and hostname were verified locally for \(host). Select the suggested chain, then Save & Verify to test the Python connector."
        } else if peer.notAfter < date || peer.notBefore > date {
            explanation = "The server certificate is expired or not valid yet. Choosing another CA cannot fix its dates."
        } else {
            explanation = "No installed certificate verified the chain and hostname for \(host). Check the server name and ask IT for its issuing chain. The server certificate has not been trusted automatically."
        }
        return .init(host: host, serverCertificate: peer, matchingIDs: matching,
                     suggestedChain: suggested, explanation: explanation)
    }

    static func configureOfflineTrust(_ trust: SecTrust, host: String) throws {
        guard let revocation = SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationUseAnyAvailableMethod | kSecRevocationNetworkAccessDisabled)) else {
            throw AppMCPError.configuration("Could not configure local certificate verification.")
        }
        try check(SecTrustSetNetworkFetchAllowed(trust, false))
        try check(SecTrustSetPolicies(trust, [SecPolicyCreateSSL(true, host as CFString), revocation] as CFArray))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw AppMCPError.configuration("Certificate verification could not be prepared (\(status)).") }
    }
}

/// All mutable state is confined to queue. Completion always rejects the TLS
/// connection: it is used only to inspect certificates, never to send application data.
final class AppMCPTLSCertificateProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TurboFieldfare.MCP.CertificateProbe")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<[Data], Error>?
    private var timeout: DispatchWorkItem?
    private var cancelled = false

    func fetch(host: String, port: UInt16 = 443, timeoutSeconds: Double = 10) async throws -> [Data] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(host: host, port: port, timeoutSeconds: timeoutSeconds, continuation: continuation) }
            }
        } onCancel: {
            self.queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) }
        }
    }

    private func start(host: String, port: UInt16, timeoutSeconds: Double, continuation: CheckedContinuation<[Data], Error>) {
        self.continuation = continuation
        guard !cancelled else { finish(.failure(CancellationError())); return }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { [weak self] _, value, complete in
            guard let self else { complete(false); return }
            do {
                let trust = sec_trust_copy_ref(value).takeRetainedValue()
                try AppMCPServerCertificates.configureOfflineTrust(trust, host: host)
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], !chain.isEmpty, chain.count <= 16 else {
                    throw AppMCPError.configuration("The server did not provide a TLS certificate chain.")
                }
                let result = chain.map { SecCertificateCopyData($0) as Data }
                guard result.reduce(0, { $0 + $1.count }) <= AppMCPCertificates.maximumFileSize else {
                    throw AppMCPError.configuration("The server certificate chain exceeds 1 MB.")
                }
                complete(false)
                self.finish(.success(result))
            } catch { complete(false); self.finish(.failure(error)) }
        }, queue)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finish(.failure(AppMCPError.configuration("Could not read the TLS certificate from \(host):\(port): \(error.localizedDescription). Check VPN and the server address.")))
            }
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(AppMCPError.configuration("Timed out reading the TLS certificate from \(host):\(port). Check VPN and the server address.")))
        }
        timeout = timer
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)
        connection.start(queue: queue)
    }

    private func finish(_ result: Result<[Data], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        continuation.resume(with: result)
    }
}
#endif
