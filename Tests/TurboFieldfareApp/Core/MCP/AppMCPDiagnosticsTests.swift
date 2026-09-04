#if os(macOS)
import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite(.serialized) @MainActor
struct AppMCPDiagnosticsTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func script(_ text: String, in root: URL, name: String = "python") throws -> URL {
        let path = root.appendingPathComponent(name)
        try text.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path
    }

    @Test func pythonCheckReportsVersionAndRejectsOldIncompleteOrInvalidSelections() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = AppMCPExchangeInstaller(directory: root.appendingPathComponent("connector"))
        for (version, major, minor, venv, expected) in [
            ("3.13.5", 3, 13, true, true), ("3.9.6", 3, 9, true, false), ("3.13.5", 3, 13, false, false)
        ] {
            let path = try script("""
            #!/bin/sh
            printf '%s\\n' '{"executable":"/fixture/python","version":"\(version)","major":\(major),"minor":\(minor),"hasVenv":\(venv),"hasEnsurepip":true}'
            """, in: root)
            let report = AppMCPDiagnostics()
            do {
                let info = try await installer.checkPython("  \(path.path)\n", diagnostics: report)
                #expect(expected)
                #expect(info.version == version && info.executable == "/fixture/python")
                #expect(report.steps.last?.state == .passed)
            } catch {
                #expect(!expected)
                #expect(error.localizedDescription.contains(version))
            }
        }
        for path in ["python3", root.path, root.appendingPathComponent("missing").path] {
            await #expect(throws: AppMCPError.self) {
                try await installer.checkPython(path, diagnostics: AppMCPDiagnostics())
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("connector").path),
                "Checking Python must not install packages or touch connector files")
    }

    @Test func pipFailureKeepsPythonSuccessAndTheExactFailedStageEvenWithAnOldReadyMarker() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("connector")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("0.2.0".utf8).write(to: destination.appendingPathComponent(".ready"))
        let python = try script("""
        #!/bin/sh
        if [ "$1" = "-I" ]; then
            printf '%s\\n' '{"executable":"/fixture/python","version":"3.13.5","major":3,"minor":13,"hasVenv":true,"hasEnsurepip":true}'
        else
            mkdir -p .venv/bin
            cat > .venv/bin/python <<'CHILD'
        #!/bin/sh
        printf '%s\\n' 'SSLError: CERTIFICATE_VERIFY_FAILED https://reader:private-password@packages.example/simple' >&2
        exit 23
        CHILD
            chmod +x .venv/bin/python
        fi
        """, in: root)
        let installer = AppMCPExchangeInstaller(directory: destination), report = AppMCPDiagnostics()
        var checked: AppMCPPythonInfo?
        do {
            _ = try await installer.install(python: python.path, diagnostics: report) { checked = $0 }
            Issue.record("Installation unexpectedly succeeded")
        } catch { report.fail(error) }
        #expect(checked?.version == "3.13.5")
        #expect(report.steps.first?.state == .passed)
        #expect(report.steps.last?.title == "Install Python dependencies")
        #expect(report.steps.last?.state == .failed)
        #expect(report.text.contains("exit 23") && report.text.contains("CERTIFICATE_VERIFY_FAILED"))
        #expect(report.text.contains("corporate CA"))
        #expect(!report.text.contains("private-password"))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(".ready").path))
    }

    @Test func verboseSetupCommandsDrainOutputAndKeepTheFinalError() async throws {
        let runner = AppMCPSetupProcess()
        do {
            _ = try await runner.run("/usr/bin/python3", ["-c", "import sys; print('x'*200000); print('FINAL_PIP_ERROR', file=sys.stderr); sys.exit(17)"],
                                     directory: nil, stage: "Dependency installation", timeout: .seconds(5))
            Issue.record("Expected command failure")
        } catch {
            #expect(error.localizedDescription.contains("exit 17"))
            #expect(error.localizedDescription.contains("FINAL_PIP_ERROR"))
            #expect(error.localizedDescription.count < 13_000)
        }
    }

    @Test func setupTimeoutAndCancellationPermitRetryWithoutLateResults() async throws {
        let runner = AppMCPSetupProcess()
        do {
            _ = try await runner.run("/usr/bin/python3", ["-c", "import time; time.sleep(10)"],
                                     directory: nil, stage: "Python check", timeout: .milliseconds(100))
            Issue.record("Expected timeout")
        } catch { #expect(error.localizedDescription.contains("timed out")) }
        let pending = Task {
            try await runner.run("/usr/bin/python3", ["-c", "import time; time.sleep(10)"],
                                  directory: nil, stage: "Python check")
        }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let output = try await runner.run("/usr/bin/python3", ["-c", "print('ready')"], directory: nil, stage: "Retry")
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "ready")
    }

    @Test func stderrExitCodesAndJSONRPCErrorsAreVisibleButCredentialsAndErrorDataAreNot() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try script("""
        import json, sys
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            if r['method'] == 'initialize':
                reply = {'result': {'protocolVersion': '2025-11-25', 'capabilities': {'tools': {}}}}
            elif r['method'] == 'error':
                reply = {'error': {'code': -32001, 'message': 'Unauthorized: credential-marker', 'data': 'PRIVATE_MAIL_BODY'}}
            else:
                print('ModuleNotFoundError: missing_connector credential-marker', file=sys.stderr, flush=True)
                sys.exit(19)
            print(json.dumps(dict(jsonrpc='2.0', id=r['id'], **reply)), flush=True)
        """, in: root, name: "server.py")
        let client = AppMCPStdioClient(timeout: .seconds(3))
        try await client.start(executable: "/usr/bin/python3", arguments: [server.path], directory: "", environment: ["API_TOKEN": "credential-marker"])
        do {
            _ = try await client.request("error", params: .object([:]))
            Issue.record("Expected JSON-RPC error")
        } catch {
            #expect(error.localizedDescription.contains("-32001") && error.localizedDescription.contains("Unauthorized"))
            #expect(!error.localizedDescription.contains("credential-marker"))
            #expect(!error.localizedDescription.contains("PRIVATE_MAIL_BODY"))
        }
        do {
            _ = try await client.request("exit", params: .object([:]))
            Issue.record("Expected process exit")
        } catch {
            #expect(error.localizedDescription.contains("code 19"))
            #expect(error.localizedDescription.contains("ModuleNotFoundError"))
            #expect(!error.localizedDescription.contains("credential-marker"))
        }
        #expect(client.lastFailure?.contains("ModuleNotFoundError") == true)
        client.stop()
    }

    @Test func initializationTimeoutExplainsThatPythonAloneIsNotAMCPServer() async throws {
        let client = AppMCPStdioClient(timeout: .milliseconds(100))
        do {
            try await client.start(executable: "/usr/bin/python3", arguments: ["-c", "import time; time.sleep(10)"], directory: "", environment: [:])
            Issue.record("Expected handshake timeout")
        } catch {
            #expect(error.localizedDescription.contains("initialize") && error.localizedDescription.contains("Python without"))
        }
        client.stop()
    }

    @Test func importFailureBeforeInitializationIncludesTheFinalStderr() async throws {
        let client = AppMCPStdioClient(timeout: .seconds(3))
        do {
            try await client.start(executable: "/usr/bin/python3", arguments: ["-c", "import definitely_missing_mcp_fixture_module"],
                                   directory: "", environment: [:])
            Issue.record("Expected an import failure")
        } catch {
            #expect(error.localizedDescription.contains("code 1"))
            #expect(error.localizedDescription.contains("ModuleNotFoundError"))
            #expect(error.localizedDescription.contains("definitely_missing_mcp_fixture_module"))
        }
        client.stop()
    }

    @Test func aServerThatClosesStdoutCannotLeaveTheConnectionWaiting() async throws {
        let client = AppMCPStdioClient(timeout: .seconds(3))
        do {
            try await client.start(executable: "/usr/bin/python3", arguments: ["-c", "import os, time; os.close(1); time.sleep(10)"],
                                   directory: "", environment: [:])
            Issue.record("Expected a closed protocol stream")
        } catch { #expect(error.localizedDescription.contains("closed stdout")) }
        client.stop()
    }

    @Test func diagnosticsRedactKnownCredentialsHeadersAndPackageURLs() {
        let secret = "quote\"back\\slash"
        let encoded = String(decoding: try! JSONEncoder().encode(secret), as: UTF8.self)
        let report = AppMCPDiagnostics(secrets: [secret])
        report.begin("Authentication")
        report.fail(AppMCPError.configuration("""
        \(secret) \(encoded)
        https://reader:hidden@packages.example/simple?token=query-secret
        Authorization: Bearer header-secret
        password="two word secret"
        CERTIFICATE_VERIFY_FAILED
        """))
        for value in [secret, "hidden", "query-secret", "header-secret", "two word secret"] {
            #expect(!report.text.contains(value))
        }
        #expect(report.text.contains("CERTIFICATE_VERIFY_FAILED"))
    }
}
#endif
