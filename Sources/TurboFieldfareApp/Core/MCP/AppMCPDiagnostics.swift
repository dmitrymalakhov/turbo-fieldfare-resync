#if os(macOS)
import Foundation
import Observation

public struct AppMCPDiagnosticStep: Identifiable, Equatable, Sendable {
    public enum State: Sendable { case running, passed, failed, cancelled }
    public let id = UUID()
    public var title: String
    public var state: State = .running
    public var detail = ""
}

/// Local, in-memory setup diagnostics. Never records requests or successful tool responses.
@MainActor @Observable
public final class AppMCPDiagnostics {
    public private(set) var steps: [AppMCPDiagnosticStep] = []
    public let startedAt = Date()
    private var secrets: [String]

    public init(secrets: [String] = []) { self.secrets = secrets }
    func redact(_ values: [String]) { secrets = values }
    public func begin(_ title: String) {
        complete()
        steps.append(.init(title: title))
    }
    public func complete(_ detail: String = "") {
        guard let index = steps.indices.last, steps[index].state == .running else { return }
        steps[index].state = .passed
        steps[index].detail = AppMCPDiagnosticText.clean(detail, secrets: secrets)
    }
    public func fail(_ error: Error) {
        guard steps.last?.state != .failed else { return }
        if steps.last?.state != .running { begin("Connection") }
        guard let index = steps.indices.last else { return }
        steps[index].state = .failed
        steps[index].detail = AppMCPDiagnosticText.clean(error.localizedDescription, secrets: secrets)
    }
    public func cancel() {
        guard let index = steps.indices.last, steps[index].state == .running else { return }
        steps[index].state = .cancelled
        steps[index].detail = "Cancelled. You can retry this step."
    }
    public var text: String {
        steps.map { "\($0.title) — \($0.state)\n\($0.detail)" }.joined(separator: "\n\n")
    }
}

enum AppMCPDiagnosticText {
    static func clean(_ text: String, secrets: [String] = [], limit: Int = 12_000) -> String {
        var value = text
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            var variants = [secret]
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { variants.append(encoded) }
            if let data = try? JSONEncoder().encode(secret), let quoted = String(data: data, encoding: .utf8) {
                variants.append(String(quoted.dropFirst().dropLast()))
            }
            for variant in variants { value = value.replacingOccurrences(of: variant, with: "[redacted]") }
        }
        for (pattern, replacement) in [
            (#"(?i)(https?://)[^\s/@]+(?::[^\s/@]*)?@"#, "$1[redacted]@"),
            (#"(?im)(authorization\s*[:=]\s*)[^\r\n]+"#, "$1[redacted]"),
            (#"(?i)((?:password|passwd|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|token)\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s&,;]+)"#, "$1[redacted]"),
            (#"\x1B\[[0-?]*[ -/]*[@-~]"#, "")
        ] {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return value.count > limit ? "[Earlier output omitted]\n" + value.suffix(limit) : value
    }

    static func hint(for text: String) -> String {
        let value = text.lowercased()
        if value.contains("certificate_verify_failed") || value.contains("sslerror") || value.contains("certificate verify failed") {
            return "Python may not see a corporate CA installed in macOS. Open Certificates → Choose from Keychain → Find for Server to identify a matching chain. Self-signed certificates are also shown. Select the certificates, save and verify again. You can also choose a PEM/CER/CRT/DER file. If no chain matches, check the hostname and certificate chain with IT. Package downloads use pip's separate CA configuration. TLS verification remains enabled."
        }
        if value.contains("unauthorized") || value.contains("invalidcredentials") || value.contains("401") || value.contains("accessdenied") || value.contains("403") {
            return "Check Authentication: username (DOMAIN\\username), password, NTLM/Basic, and EWS mailbox permissions."
        }
        if value.contains("getaddrinfo") || value.contains("nameresolution") || value.contains("nodename") || value.contains("name or service not known") {
            return "The host name could not be resolved. Check the server address, corporate DNS and VPN."
        }
        if value.contains("timed out") || value.contains("timeout") || value.contains("connection refused") || value.contains("proxyerror") {
            return "Check VPN, the server or package proxy address, and network access."
        }
        if value.contains("no module named") || value.contains("modulenotfounderror") || value.contains("bad interpreter") {
            return "The connector's Python environment is incomplete or no longer available. Use Install / Repair Connector with a working Python 3.10+."
        }
        if value.contains("no matching distribution") || value.contains("requires-python") {
            return "Check the Python version and whether the configured package index has the required package versions."
        }
        return ""
    }

    static func failure(_ summary: String, details: String, secrets: [String] = []) -> AppMCPError {
        let cleanDetails = clean(details, secrets: secrets)
        let hint = hint(for: cleanDetails)
        return .configuration([summary, cleanDetails, hint].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
}

/// Drains output even after the display limit, preventing a verbose child from blocking on a full pipe.
final class AppMCPDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var truncated = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > 65_536 { bytes = Data(bytes.suffix(65_536)); truncated = true }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return (truncated ? "[Earlier output omitted]\n" : "") + String(decoding: bytes, as: UTF8.self)
    }
}
#endif
