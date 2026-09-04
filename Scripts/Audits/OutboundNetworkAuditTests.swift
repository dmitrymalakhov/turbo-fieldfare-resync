import AppKit
import Foundation
import Synchronization
import Testing
import TurboFieldfare
import TurboFieldfareMacPresentation

// Temporary audit probe. Every Foundation HTTP(S) request is intercepted and
// failed locally. Only method/host/path/body length are retained, never headers.
private final class AuditNetworkTrap: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[String]>([])
    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let summary = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(request.url?.path ?? "") bodyBytes=\(request.httpBody?.count ?? 0)"
        Self.requests.withLock { $0.append(summary) }
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }
    override func stopLoading() {}
}

@Suite(.serialized)
@MainActor
struct OutboundNetworkAuditTests {
    @Test func observeLocalAndFallbackPathsWithoutSendingRequests() async throws {
        #expect(URLProtocol.registerClass(AuditNetworkTrap.self))
        defer { URLProtocol.unregisterClass(AuditNetworkTrap.self) }

        // Verify interception before exercising any application path.
        _ = try? await URLSession.shared.data(from: URL(string: "https://audit.invalid/control")!)
        #expect(AuditNetworkTrap.requests.withLock { $0.count } == 1)
        AuditNetworkTrap.requests.withLock { $0 = [] }

        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scratch/gemma4.gturbo/tokenizer")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path))
        let tokenizer = try await GFTokenizer.load(from: folder)
        let sentinel = "LOCAL_NETWORK_AUDIT_SENTINEL"
        #expect(tokenizer.decode(tokenizer.encode(sentinel, addBOS: false)) == sentinel)
        #expect(AuditNetworkTrap.requests.withLock { $0.isEmpty })
        print("AUDIT: local tokenizer load and encode/decode: 0 HTTP(S) requests")

        let renderer = ResponseMarkdownRenderer()
        _ = renderer.render("![tracking](https://audit.invalid/pixel) <img src=\"https://audit.invalid/html-pixel\"> [link](https://audit.invalid/page)")
        try await Task.sleep(for: .milliseconds(100))
        #expect(AuditNetworkTrap.requests.withLock { $0.isEmpty })
        print("AUDIT: markdown images, inline HTML and links rendered: 0 HTTP(S) requests")

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-tokenizer-audit-\(UUID())")
        do {
            _ = try await GFTokenizer.load(forModelDirectory: missing, environment: [:])
            Issue.record("Missing-tokenizer fallback unexpectedly succeeded with every HTTP(S) request blocked")
        } catch {
            print("AUDIT: missing-tokenizer fallback ended with \(String(reflecting: type(of: error)))")
        }
        let requests = AuditNetworkTrap.requests.withLock { $0 }
        #expect(!requests.isEmpty, "Expected the known online fallback to attempt a request; an offline host can make this probe inconclusive")
        for request in requests { print("AUDIT: blocked before transmission: \(request)") }
        #expect(!requests.contains { $0.contains(sentinel) })
    }
}
