import AppKit
import SwiftUI
import Testing
import TurboFieldfareAppCore
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
