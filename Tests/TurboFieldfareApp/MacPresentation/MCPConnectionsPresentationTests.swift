import AppKit
import SwiftUI
import Testing
@testable import TurboFieldfareAppCore
@testable import TurboFieldfareMacPresentation

@MainActor
private final class MCPUIPreviewSecrets: AppMCPSecretStoring {
    var values: [UUID: AppMCPCredentials] = [:]
    func read(id: UUID) throws -> AppMCPCredentials { values[id] ?? .init() }
    func write(_ credentials: AppMCPCredentials, id: UUID) throws { values[id] = credentials }
    func remove(id: UUID) throws { values[id] = nil }
}

@MainActor
private final class MCPPreviewClient: AppMCPClient {
    var onDisconnect: (@MainActor () -> Void)?
    var failTool = false
    func start(executable: String, arguments: [String], directory: String, environment: [String: String]) async throws {}
    func stop() {}
    func request(_ method: String, params: AppMCPValue) async throws -> AppMCPValue {
        if method == "tools/list" {
            return .object(["tools": .array([
                .object(["name": .string("check_connection"), "inputSchema": .object([:])]),
                .object(["name": .string("list_messages"), "description": .string("Read messages in a folder for the selected calendar period."),
                         "inputSchema": .object(["type": .string("object"), "properties": .object([
                            "period": .object(["type": .string("string"), "default": .string("today")]),
                            "folder": .object(["type": .string("string"), "default": .string("Inbox")])])])])
            ])])
        }
        if params["name"]?.stringValue == "check_connection" {
            return .object(["structuredContent": .object(["authenticated": .bool(true)])])
        }
        if failTool {
            return .object(["isError": .bool(true), "content": .array([
                .object(["type": .string("text"), "text": .string("Folder not found: Project. Check the folder name and try again.")])])])
        }
        return .object(["structuredContent": .object([
            "messages": .array([.object(["subject": .string("Weekly project update — sample data"),
                "from": .object(["email": .string("colleague@example.com")]),
                "datetime_received": .string("2026-09-04T09:15:00+03:00")])]),
            "next_page": .null])])
    }
}

@Suite(.serialized)
@MainActor
struct MCPConnectionsPresentationTests {
    @Test func smtpSettingsAndComposerRenderWithoutNetwork() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smtp-preview-\(UUID())")
        let manager = AppMCPManager(store: .init(fileURL: root.appendingPathComponent("profiles.json")), secrets: MCPUIPreviewSecrets())
        var profile = AppMCPProfile(kind: .smtp)
        profile.server = "smtp.example.invalid"; profile.email = "sender@example.invalid"; profile.username = "sender"
        let screenshots = FileManager.default.temporaryDirectory.appendingPathComponent("TurboFieldfare-MCP-previews")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try renderView(MCPProfileEditor(profile: profile, manager: manager).preferredColorScheme(.light),
                       size: NSSize(width: 610, height: 690), to: screenshots.appendingPathComponent("smtp-settings.png"))
        try renderView(SMTPComposeView(profile: profile, manager: manager).preferredColorScheme(.light),
                       size: NSSize(width: 650, height: 590), to: screenshots.appendingPathComponent("smtp-compose.png"))
    }

    @Test func certificatePickerAndSettingsRenderWithoutReadingKeychain() throws {
        _ = NSApplication.shared
        let file = try #require(Bundle.module.url(forResource: "mcp-corporate-ca", withExtension: "der", subdirectory: "Fixtures"))
        let selection = try AppMCPCertificates.readFile(file)
        let selfSignedFile = try #require(Bundle.module.url(forResource: "mcp-matching-selfSignedServer", withExtension: "der", subdirectory: "Fixtures"))
        let certificates = try AppMCPCertificates.inspect(selection) + [AppMCPCertificate(der: Data(contentsOf: selfSignedFile))]
        let screenshots = FileManager.default.temporaryDirectory.appendingPathComponent("TurboFieldfare-MCP-previews")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try renderView(MCPKeychainCertificatePicker(host: "mail.example.invalid", certificates: certificates) { _ in }
            .preferredColorScheme(.light), size: NSSize(width: 780, height: 750),
            to: screenshots.appendingPathComponent("certificate-picker.png"))
        var profile = AppMCPProfile(); profile.selectedCertificates = selection
        try renderView(MCPCertificateSettingsView(profile: .constant(profile)).padding(24)
            .frame(width: 620, height: 390, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light),
            size: NSSize(width: 620, height: 390), to: screenshots.appendingPathComponent("certificate-selected.png"))

        let rootFile = try #require(Bundle.module.url(forResource: "mcp-matching-root", withExtension: "der", subdirectory: "Fixtures"))
        let issuerFile = try #require(Bundle.module.url(forResource: "mcp-matching-intermediate", withExtension: "der", subdirectory: "Fixtures"))
        let serverFile = try #require(Bundle.module.url(forResource: "mcp-matching-server", withExtension: "der", subdirectory: "Fixtures"))
        let root = try AppMCPCertificates.inspect(AppMCPCertificates.readFile(rootFile))[0]
        let issuer = try AppMCPCertificates.inspect(AppMCPCertificates.readFile(issuerFile))[0]
        let server = try AppMCPCertificate(der: Data(contentsOf: serverFile))
        let suggested = AppMCPCertificateSuggestion(host: "mail.example.invalid", serverCertificate: server,
            matchingIDs: [root.id], suggestedChain: [issuer, root], explanation: "A certificate path and hostname were verified locally for mail.example.invalid. Select the suggested chain, then Save & Verify to test the Python connector.")
        try renderView(MCPKeychainCertificatePicker(host: "mail.example.invalid", certificates: certificates + [root], suggestion: suggested) { _ in }
            .preferredColorScheme(.light), size: NSSize(width: 780, height: 750),
            to: screenshots.appendingPathComponent("certificate-matching.png"))
    }

    @Test func pythonDiscoveryPickerShowsVerifiedVersionsAndManualFallback() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-python-picker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for version in ["3.13", "3.14", "3.9"] {
            let path = directory.appendingPathComponent("python\(version)")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let discovery = AppMCPPythonDiscovery(locations: [.init(directory: directory, source: "Homebrew")]) { path in
            let version = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: "python", with: "")
            return AppMCPPythonInfo(executable: path, version: version + ".5", major: 3,
                                   minor: Int(version.split(separator: ".")[1])!, hasVenv: true, hasEnsurepip: true)
        }
        discovery.search()
        for _ in 0..<100 where discovery.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(discovery.installations.filter(\.isCompatible).count == 2)
        let manager = AppMCPManager(store: .init(fileURL: directory.appendingPathComponent("profiles.json")), secrets: MCPUIPreviewSecrets())
        var profile = AppMCPProfile(); profile.pythonExecutable = directory.appendingPathComponent("python3.13").path
        let screenshots = FileManager.default.temporaryDirectory.appendingPathComponent("TurboFieldfare-MCP-previews")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try renderView(MCPPythonSetupView(manager: manager, profile: profile, discovery: discovery)
            .padding(24).frame(width: 760, height: 600, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light),
            size: NSSize(width: 760, height: 600), to: screenshots.appendingPathComponent("python-discovery.png"))
    }

    @Test func diagnosticsRenderPythonSuccessAndExpandedInstallFailure() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-diagnostic-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let python = directory.appendingPathComponent("python")
        try """
        #!/bin/sh
        if [ "$1" = "-I" ]; then
            printf '%s\\n' '{"executable":"/opt/homebrew/bin/python3.13","version":"3.13.5","major":3,"minor":13,"hasVenv":true,"hasEnsurepip":true}'
        else
            mkdir -p .venv/bin
            cat > .venv/bin/python <<'CHILD'
        #!/bin/sh
        printf '%s\\n' 'SSLError: CERTIFICATE_VERIFY_FAILED' >&2
        exit 1
        CHILD
            chmod +x .venv/bin/python
        fi
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python.path)
        let manager = AppMCPManager(store: .init(fileURL: directory.appendingPathComponent("profiles.json")), secrets: MCPUIPreviewSecrets(),
                                    installerFactory: { AppMCPExchangeInstaller(directory: directory.appendingPathComponent("connector")) })
        var profile = AppMCPProfile(); profile.server = "mail.company.com"
        profile.email = "you@company.com"; profile.username = "CORP\\username"
        try manager.save(profile, credentials: .init())
        manager.installExchange(profile.id, python: python.path)
        for _ in 0..<500 where manager.status(profile.id).isBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(manager.pythonInfo[profile.id]?.version == "3.13.5")
        let report = try #require(manager.diagnostics[profile.id])
        #expect(report.steps.last?.state == .failed)
        if case .failed = manager.status(profile.id) {} else { Issue.record("Expected installation failure") }
        let screenshots = FileManager.default.temporaryDirectory.appendingPathComponent("TurboFieldfare-MCP-previews")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try renderView(MCPDiagnosticsView(report: report).padding(24).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light),
                       size: NSSize(width: 750, height: 600), to: screenshots.appendingPathComponent("diagnostics-error.png"))
        try render(manager, selection: profile.id, to: screenshots.appendingPathComponent("python-verified.png"))
        manager.stopAll()
    }

    @Test func testConsoleRendersRequestDataAndToolErrorWithoutAModel() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MCPPreviewClient()
        let manager = AppMCPManager(store: .init(fileURL: directory.appendingPathComponent("profiles.json")),
                                    secrets: MCPUIPreviewSecrets(), factory: { client })
        var profile = AppMCPProfile(kind: .exchange)
        profile.name = "Work Exchange"; profile.email = "you@company.com"
        profile.username = "CORP\\username"; profile.server = "mail.company.com"; profile.executable = "/preview/exchange-mcp"
        try manager.save(profile, credentials: .init(password: "preview-only"))
        try await manager.ensureConnected(profile.id)
        defer { manager.stopAll() }
        let screenshots = FileManager.default.temporaryDirectory.appendingPathComponent("TurboFieldfare-MCP-previews")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try renderView(MCPConnectionTestView(manager: manager, profileID: profile.id).preferredColorScheme(.light),
                       size: NSSize(width: 800, height: 800), to: screenshots.appendingPathComponent("tester-ready.png"))
        let tool = try #require(manager.tools[profile.id]?.first)
        for fails in [false, true] {
            let runner = AppMCPConnectionTest()
            client.failTool = fails
            runner.start(manager: manager, id: profile.id, tool: tool,
                         argumentsJSON: AppMCPTestInput.template(tool: tool, kind: .exchange))
            for _ in 0..<100 where runner.isRunning { try await Task.sleep(for: .milliseconds(5)) }
            #expect(runner.result?.isError == fails)
            try renderView(MCPConnectionTestView(manager: manager, profileID: profile.id, runner: runner).preferredColorScheme(.light),
                           size: NSSize(width: 800, height: 800),
                           to: screenshots.appendingPathComponent(fails ? "tester-error.png" : "tester-data.png"))
        }
    }

    @Test func settingsRenderWithoutLoadingAModel() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-ui-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppMCPProfileStore(fileURL: directory.appendingPathComponent("profiles.json"))
        let manager = AppMCPManager(store: store, secrets: MCPUIPreviewSecrets())
        let screenshots = FileManager.default.temporaryDirectory.appendingPathComponent("TurboFieldfare-MCP-previews")
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try render(manager, to: screenshots.appendingPathComponent("empty.png"))
        try renderView(MCPConnectionPicker(select: { _ in }).preferredColorScheme(.light),
                       size: NSSize(width: 610, height: 690), to: screenshots.appendingPathComponent("add-server.png"))
        var local = AppMCPProfile(kind: .stdio)
        local.name = "Project tools"; local.executable = "/usr/bin/python3"
        local.arguments = ["-m", "project_tools"]; local.environmentKeys = ["API_TOKEN"]
        try manager.save(local, credentials: .init())
        var profile = AppMCPProfile(kind: .exchange)
        profile.name = "Work Exchange"; profile.email = "you@company.com"
        profile.username = "CORP\\username"; profile.server = "mail.company.com"
        try manager.save(profile, credentials: .init())
        try render(manager, to: screenshots.appendingPathComponent("overview.png"))
        try render(manager, selection: local.id, to: screenshots.appendingPathComponent("local-server.png"))
        try render(manager, selection: profile.id, to: screenshots.appendingPathComponent("exchange.png"))
        try renderView(MCPProfileEditor(profile: local, manager: manager)
            .preferredColorScheme(.light), size: NSSize(width: 610, height: 690),
                       to: screenshots.appendingPathComponent("local-settings.png"))
        try renderView(MCPProfileEditor(profile: profile, manager: manager)
            .frame(width: 610, height: 690).preferredColorScheme(.light),
                       size: NSSize(width: 610, height: 690), to: screenshots.appendingPathComponent("authentication.png"))
    }

    private func render(_ manager: AppMCPManager, selection: UUID? = nil, to destination: URL) throws {
        let view = MCPConnectionsView(manager: manager, initialSelection: selection)
            .frame(width: 980, height: 760).preferredColorScheme(.light)
        try renderView(view, size: NSSize(width: 980, height: 760), to: destination)
    }

    private func renderView<V: View>(_ view: V, size: NSSize, to destination: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: destination)
        #expect(png.count > 5_000)
        window.close()
    }
}
