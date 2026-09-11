#if os(macOS)
import Foundation
import Testing
@testable import TurboFieldfareAppCore

@MainActor
private final class MCPTestSecrets: AppMCPSecretStoring {
    var values: [UUID: AppMCPCredentials] = [:]
    var removeError: Error?
    func read(id: UUID) throws -> AppMCPCredentials { values[id] ?? .init() }
    func write(_ credentials: AppMCPCredentials, id: UUID) throws { values[id] = credentials }
    func remove(id: UUID) throws {
        if let removeError { throw removeError }
        values[id] = nil
    }
}

@MainActor
private final class MCPTestClient: AppMCPClient {
    var onDisconnect: (@MainActor () -> Void)?
    var stopCount = 0
    var environment: [String: String] = [:]
    var calls: [(String, AppMCPValue)] = []
    var authenticationFails = false
    var authenticationError = ""
    var mailCount = 237
    var mailDelay: Duration?
    var toolReply: AppMCPValue?
    var advertisedTools = ["check_connection", "list_messages", "get_message", "list_calendar_events", "send_email"]
    func start(executable: String, arguments: [String], directory: String, environment: [String: String]) async throws {
        self.environment = environment
    }
    func request(_ method: String, params: AppMCPValue) async throws -> AppMCPValue {
        calls.append((method, params))
        if method == "tools/list" {
            return .object(["tools": .array(advertisedTools.map {
                .object(["name": .string($0), "inputSchema": .object(["type": .string("object")]),
                         "annotations": .object(["readOnlyHint": .bool(true)])])
            })])
        }
        let name = params["name"]?.stringValue
        if name == "check_connection" {
            return .object(["isError": .bool(authenticationFails), "structuredContent": .object(["authenticated": .bool(true)]),
                            "content": .array([.object(["type": .string("text"), "text": .string(authenticationError)])])])
        }
        if let toolReply { return toolReply }
        if name == "list_messages" {
            if let mailDelay { try await Task.sleep(for: mailDelay) }
            let offset = params["arguments"]?["offset"]?.intValue ?? 0
            let end = min(offset + 10, mailCount)
            return .object(["structuredContent": .object([
                "start_inclusive": .string("2026-08-31T00:00:00+03:00"),
                "end_exclusive": .string("2026-09-04T13:00:00+03:00"),
                "messages": .array((offset..<end).map { i in .object([
                    "id": .string("mail-\(i)"), "subject": .string("Subject \(i)"), "body": .string("Body \(i)"),
                    "body_next_offset": .null]) }),
                "next_page": end < mailCount ? .object(["offset": .number(Double(end))]) : .null])])
        }
        return .object(["structuredContent": .object([:])])
    }
    func stop() { stopCount += 1 }
}

private final class MCPContextPreparingClient: AppGenerationRequestPreparing, @unchecked Sendable {
    let inner = MockInferenceClient(response: "Answer", tokenDelayNanos: 1)
    func prepare(_ request: AppGenerationRequest) async throws -> AppGenerationRequest {
        if request.prompt.count > 2_000 {
            throw AppInferenceError.contextOverflow(prompt: request.prompt.count, maxNew: 100, maxContext: 2_000)
        }
        return request
    }
    func generate(_ request: AppGenerationRequest) -> AsyncThrowingStream<AppInferenceEvent, Error> { inner.generate(request) }
    func cancel() { inner.cancel() }
}

@MainActor
private final class MCPLargeContextProvider: AppPromptContextProviding {
    func prepare(prompt: String, recentUserPrompts: [String], progress: @escaping @MainActor (String) -> Void) async throws -> AppExternalPromptContext? {
        AppExternalPromptContext(attachment: AppPromptAttachment(fileName: "Mail", formatLabel: "Mail",
            extractedText: String(repeating: "Fixture mail body. ", count: 10_000)), summary: "Почта: тестовая выборка")
    }
}

@Suite(.serialized)
@MainActor
struct AppMCPTests {
    private func temporaryStore() throws -> AppMCPProfileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return .init(fileURL: root.appendingPathComponent("connections.json"))
    }
    private func profile() -> AppMCPProfile {
        var value = AppMCPProfile()
        value.server = "mail.example.com"; value.email = "reader@example.com"; value.username = "CORP\\reader"
        value.executable = "/test/exchange-mcp"
        return value
    }
    private func settle(_ manager: AppMCPManager, id: UUID) async throws {
        for _ in 0..<100 {
            if !manager.status(id).isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Connection operation did not finish")
    }

    @Test func profilesPersistWithoutAnySecrets() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient()
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        var value = profile(); value.environmentKeys = ["API_TOKEN"]
        try manager.save(value, credentials: .init(password: "password-must-not-be-in-json", environment: ["API_TOKEN": "secret-token-value"]))
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!json.contains("password-must-not-be-in-json"))
        #expect(!json.contains("secret-token-value"))
        #expect(try store.load() == [value])
        #expect(secrets.values[value.id]?.password == "password-must-not-be-in-json")
        try manager.remove(value.id)
        #expect(secrets.values[value.id] == nil)
        #expect(try store.load().isEmpty)
    }

    @Test func removingIntegrationStopsItAndCleansEveryLocalArtifact() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        try manager.save(value, credentials: .init(password: "test-password"))
        try manager.setCertificates(.init(certificates: [MCPCertificateFixtures.root], source: "Test"), for: value.id)
        manager.connect(value.id); try await settle(manager, id: value.id)
        #expect(manager.status(value.id) == .connected)
        let certificatePath = try #require(client.environment["REQUESTS_CA_BUNDLE"])
        #expect(FileManager.default.fileExists(atPath: certificatePath))
        #expect(manager.tools[value.id] != nil)
        #expect(manager.diagnostics[value.id] != nil)

        try manager.remove(value.id)

        #expect(manager.profiles.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(secrets.values[value.id] == nil)
        #expect(client.stopCount > 0)
        #expect(!FileManager.default.fileExists(atPath: certificatePath))
        #expect(manager.tools[value.id] == nil)
        #expect(manager.diagnostics[value.id] == nil)
        #expect(manager.pythonInfo[value.id] == nil)
        #expect(manager.lastChecked[value.id] == nil)
        let provider = AppMCPPromptContextProvider(manager: manager)
        let callsAfterRemoval = client.calls.count
        let context = try await provider.prepare(prompt: "Почта за сегодня", recentUserPrompts: [], progress: { _ in })
        #expect(context == nil)
        #expect(client.calls.count == callsAfterRemoval, "A removed integration must never receive chat requests")
    }

    @Test func keychainCleanupFailureDoesNotKeepIntegrationInChat() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        try manager.save(value, credentials: .init(password: "test-password"))
        manager.connect(value.id); try await settle(manager, id: value.id)
        secrets.removeError = AppMCPError.configuration("Keychain fixture is locked")

        #expect(throws: AppMCPError.self) { try manager.remove(value.id) }

        #expect(manager.profiles.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(client.stopCount > 0)
        #expect(secrets.values[value.id]?.password == "test-password")
        let provider = AppMCPPromptContextProvider(manager: manager)
        let callsAfterRemoval = client.calls.count
        let context = try await provider.prepare(prompt: "Почта за сегодня", recentUserPrompts: [], progress: { _ in })
        #expect(context == nil)
        #expect(client.calls.count == callsAfterRemoval)
    }

    @Test func certificateChoiceReachesOnlyExchangeAndCanBeResetWithoutChangingCredentials() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        try manager.save(value, credentials: .init(password: "test-password"))
        let selection = AppMCPCertificateSelection(certificates: [MCPCertificateFixtures.root], source: "Keychain")
        try manager.setCertificates(selection, for: value.id)
        #expect(try store.load().first?.selectedCertificates == selection)
        #expect(secrets.values[value.id]?.password == "test-password")
        manager.connect(value.id); try await settle(manager, id: value.id)
        #expect(manager.status(value.id) == .connected)
        #expect(client.environment["EXCHANGE_VERIFY_SSL"] == "true")
        let bundle = try #require(client.environment["REQUESTS_CA_BUNDLE"])
        #expect(try AppMCPCertificates.decode(Data(contentsOf: URL(fileURLWithPath: bundle))).map(\.der) == [MCPCertificateFixtures.root])
        #expect(manager.diagnostics[value.id]?.text.contains("Source: Keychain") == true)
        try manager.setCertificates(nil, for: value.id)
        #expect(manager.status(value.id) == .disconnected)
        manager.connect(value.id); try await settle(manager, id: value.id)
        #expect(client.environment["REQUESTS_CA_BUNDLE"] == nil)
        #expect(client.environment["EXCHANGE_VERIFY_SSL"] == "true")
        manager.stopAll()
    }

    @Test func missingCertificateFailsBeforeStartingMCPOrSendingCredentials() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient()
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        var value = profile(); value.certificateBundle = store.fileURL.deletingLastPathComponent().appendingPathComponent("missing.pem").path
        try manager.save(value, credentials: .init(password: "test-password"))
        manager.connect(value.id); try await settle(manager, id: value.id)
        if case .failed = manager.status(value.id) {} else { Issue.record("Missing certificate must stop connection") }
        #expect(client.environment.isEmpty && client.calls.isEmpty)
        #expect(manager.diagnostics[value.id]?.steps.last?.title == "Prepare Exchange TLS certificates")
    }

    @Test func exchangeConnectionChecksMailboxAndFiltersEvenMislabelledSendTool() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        try manager.save(value, credentials: .init(password: "local-test-password"))
        manager.connect(value.id); try await settle(manager, id: value.id)
        #expect(manager.status(value.id) == .connected)
        #expect(client.environment["EXCHANGE_PASSWORD"] == "local-test-password")
        #expect(client.calls.contains { $0.1["name"]?.stringValue == "check_connection" })
        #expect(manager.tools[value.id]?.contains { $0.name == "send_email" } == false)
        await #expect(throws: AppMCPError.self) { try await manager.call(value.id, tool: "send_email", arguments: .object([:])) }
        try manager.setToolEnabled("list_messages", enabled: false, id: value.id)
        await #expect(throws: AppMCPError.self) { try await manager.call(value.id, tool: "list_messages", arguments: .object([:])) }
        await #expect(throws: AppMCPError.self) { try await manager.callRaw(value.id, tool: "list_messages", arguments: .object([:])) }
        manager.stopAll()
    }

    @Test func failedAuthenticationNeverShowsConnected() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(); client.authenticationFails = true
        let value = profile(), manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "test"))
        manager.connect(value.id); try await settle(manager, id: value.id)
        if case .failed = manager.status(value.id) {} else { Issue.record("Authentication failure must remain visible") }
        #expect(manager.lastChecked[value.id] == nil)
        #expect(client.stopCount > 0)
    }

    @Test func authenticationDiagnosticsPreserveTheFailingStageAndHidePassword() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(); client.authenticationFails = true
        client.authenticationError = "InvalidCredentials: HTTP 401 auth-secret"
        let value = profile(), manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "auth-secret"))
        manager.connect(value.id); try await settle(manager, id: value.id)
        let report = try #require(manager.diagnostics[value.id])
        #expect(report.steps.last?.title == "Verify Exchange sign-in and Inbox access")
        #expect(report.steps.last?.state == .failed)
        #expect(report.text.contains("HTTP 401") && report.text.contains("EWS mailbox permissions"))
        #expect(!report.text.contains("auth-secret"))
        if case .failed(let message) = manager.status(value.id) { #expect(!message.contains("auth-secret")) }
        else { Issue.record("Authentication must fail") }
        client.authenticationFails = false
        manager.connect(value.id); try await settle(manager, id: value.id)
        #expect(manager.status(value.id) == .connected)
        #expect(manager.diagnostics[value.id]?.steps.allSatisfy { $0.state == .passed } == true)
        manager.stopAll()
    }

    @Test func pythonSelectionPersistsButOnlyACompletedCheckShowsVerified() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let path = store.fileURL.deletingLastPathComponent().appendingPathComponent("fixture-python")
        try """
        #!/bin/sh
        printf '%s\\n' '{"executable":"/fixture/python","version":"3.13.5","major":3,"minor":13,"hasVenv":true,"hasEnsurepip":true}'
        """.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let value = profile(), secrets = MCPTestSecrets()
        let manager = AppMCPManager(store: store, secrets: secrets)
        try manager.save(value, credentials: .init(password: "local-only"))
        manager.checkPython(value.id, python: path.path); try await settle(manager, id: value.id)
        #expect(manager.status(value.id) == .disconnected, "Python success is not mailbox authentication")
        #expect(manager.pythonInfo[value.id]?.version == "3.13.5")
        #expect(try store.load().first?.pythonExecutable == path.path)
        let restored = AppMCPManager(store: store, secrets: secrets)
        #expect(restored.pythonInfo[value.id] == nil)
        manager.checkPython(value.id, python: path.path + "-missing"); try await settle(manager, id: value.id)
        #expect(manager.pythonInfo[value.id] == nil)
        #expect(manager.diagnostics[value.id]?.steps.last?.state == .failed)
        let data = try JSONEncoder().encode(value)
        let legacy = try JSONDecoder().decode(AppMCPProfile.self, from: data)
        #expect(legacy.pythonExecutable == nil)
        manager.stopAll()
    }

    @Test func exchangeRejectsWriteToolsEvenWhenPersistedAndAdvertisedAsReadOnly() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let forbidden = ["send_email", "reply", "forward", "create_draft", "update_message", "delete_message",
                         "move_message", "copy_message", "mark_as_read", "mark_as_unread", "set_categories",
                         "create_event", "update_event", "delete_event", "accept_meeting", "decline_meeting",
                         "execute", "SendItem", "UpdateItem", "DeleteItem"]
        let client = MCPTestClient()
        client.advertisedTools = ["check_connection", "list_messages", "get_message", "list_calendar_events"] + forbidden
        var value = profile()
        // A hand-edited or older settings file must not bypass the Exchange policy.
        value.enabledTools.formUnion(forbidden)
        let secrets = MCPTestSecrets()
        try store.save([value])
        try secrets.write(.init(password: "test"), id: value.id)
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        manager.connect(value.id); try await settle(manager, id: value.id)
        defer { manager.stopAll() }
        #expect(manager.status(value.id) == .connected)
        #expect(Set(manager.tools[value.id, default: []].map(\.name)) == AppMCPManager.exchangeTools)
        let requestsBefore = client.calls.count
        for tool in forbidden {
            #expect(throws: AppMCPError.self) { try manager.setToolEnabled(tool, enabled: true, id: value.id) }
            await #expect(throws: AppMCPError.self) {
                try await manager.call(value.id, tool: tool, arguments: .object([:]))
            }
            await #expect(throws: AppMCPError.self) {
                try await manager.callRaw(value.id, tool: tool, arguments: .object([:]))
            }
        }
        #expect(client.calls.count == requestsBefore, "Forbidden operations must never reach the connector")
    }

    @Test func disabledToolsRemainDisabledAcrossReconnectAndReload() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let secrets = MCPTestSecrets(), client = MCPTestClient()
        var value = profile(); value.enabledTools = []
        let manager = AppMCPManager(store: store, secrets: secrets, factory: { client })
        try manager.save(value, credentials: .init(password: "test"))
        manager.connect(value.id); try await settle(manager, id: value.id); manager.stopAll()
        let restored = AppMCPManager(store: store, secrets: secrets, factory: { MCPTestClient() })
        restored.connect(value.id); try await settle(restored, id: value.id)
        #expect(restored.profiles.first?.enabledTools.isEmpty == true)
        restored.stopAll()
    }

    @Test func readsEveryPageOfWeeklyMail() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "test"))
        manager.connect(value.id); try await settle(manager, id: value.id)
        let snapshot = try await manager.readMail(value.id, period: "this_week", folder: "Inbox")
        #expect(snapshot.count == 237)
        #expect(snapshot.complete)
        #expect(snapshot.text.contains("Body 236"))
        #expect(client.calls.filter { $0.1["name"]?.stringValue == "list_messages" }.count == 24)
        manager.stopAll()
    }

    private func settleTest(_ test: AppMCPConnectionTest) async throws {
        for _ in 0..<100 {
            if !test.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("MCP test operation did not finish")
    }

    @Test func testerDisplaysPlainTextToolErrorsAndEmptyData() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient()
        client.advertisedTools = ["read_items"]
        var value = AppMCPProfile(kind: .stdio)
        value.executable = "/test/local-mcp"; value.enabledTools = ["read_items"]
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init())
        try await manager.ensureConnected(value.id)
        defer { manager.stopAll() }
        let tool = try #require(manager.tools[value.id]?.first), test = AppMCPConnectionTest()
        let replies: [AppMCPValue] = [
            .object(["content": .array([.object(["type": .string("text"), "text": .string("A plain text response")])])]),
            .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string("Unknown folder: Project")])])]),
            .object(["structuredContent": .object(["messages": .array([])])])
        ]
        for reply in replies {
            client.toolReply = reply
            test.start(manager: manager, id: value.id, tool: tool, argumentsJSON: "{}")
            try await settleTest(test)
            let result = try #require(test.result)
            #expect(test.error == nil)
            #expect(result.response == reply)
            #expect(result.isError == (reply["isError"]?.boolValue == true))
            #expect(result.byteCount > 0 && result.elapsed >= 0)
            #expect(result.tool == "read_items" && result.arguments == .object([:]))
        }
        #expect(test.result?.summary.contains("0 messages") == true)
        #expect(client.calls.filter { $0.0 == "tools/call" }.count == 3)
        test.clear()
        #expect(test.result == nil && test.error == nil)
        manager.disconnect(value.id)
        test.start(manager: manager, id: value.id, tool: tool, argumentsJSON: "{}")
        try await settleTest(test)
        #expect(test.result == nil && test.error != nil)
    }

    @Test func testerValidatesInputAndCancelsWithoutLateResults() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "test"))
        try await manager.ensureConnected(value.id)
        defer { manager.stopAll() }
        let tool = AppMCPTool(name: "list_messages", schema: .object(["required": .array([.string("period")])]))
        let test = AppMCPConnectionTest(), count = client.calls.count
        for invalid in ["not JSON", "[]", "null", "{}"] {
            test.start(manager: manager, id: value.id, tool: tool, argumentsJSON: invalid)
            #expect(!test.isRunning && test.error != nil)
        }
        #expect(client.calls.count == count)
        client.mailDelay = .seconds(30)
        test.start(manager: manager, id: value.id, tool: tool, argumentsJSON: "{\"period\":\"today\"}")
        for _ in 0..<100 where client.calls.count == count { try await Task.sleep(for: .milliseconds(5)) }
        #expect(client.calls.count == count + 1)
        test.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!test.isRunning && test.result == nil && test.error?.contains("cancelled") == true)
        client.mailDelay = nil; client.mailCount = 1
        test.start(manager: manager, id: value.id, tool: tool, argumentsJSON: "{\"period\":\"yesterday\"}")
        try await settleTest(test)
        #expect(test.result?.arguments["period"]?.stringValue == "yesterday")
        #expect(test.error == nil)
    }

    @Test func exchangeTestPresetsMakeOneReadRequestAndDoNotFollowPages() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(), value = profile()
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "test"))
        try await manager.ensureConnected(value.id)
        defer { manager.stopAll() }
        let tool = try #require(manager.tools[value.id]?.first { $0.name == "list_messages" })
        let test = AppMCPConnectionTest()
        for period in ["today", "yesterday", "this_week"] {
            let count = client.calls.count
            test.start(manager: manager, id: value.id, tool: tool,
                       argumentsJSON: AppMCPTestInput.template(tool: tool, kind: .exchange, period: period))
            try await settleTest(test)
            #expect(client.calls.count == count + 1)
            let arguments = try #require(client.calls.last?.1["arguments"])
            #expect(arguments["period"]?.stringValue == period)
            #expect(arguments["page_size"]?.intValue == 3)
            #expect(arguments["include_body"]?.boolValue == false)
            #expect(test.result?.response["structuredContent"]?["next_page"] != nil)
        }
    }

    @Test func malformedProfilesArePreserved() throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let broken = Data("{unreadable}".utf8)
        try broken.write(to: store.fileURL)
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets())
        #expect(manager.error != nil)
        #expect(throws: AppMCPError.self) { try manager.save(profile(), credentials: .init()) }
        #expect(try Data(contentsOf: store.fileURL) == broken)
    }

    @Test func promptReadsMailAutomaticallyAndPassesItToInference() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(); client.mailCount = 2
        let value = profile(), manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "never-pass-password-to-model"))
        defer { manager.stopAll() }
        let model = promptModel(store, provider: AppMCPPromptContextProvider(manager: manager))
        let privateInstruction = "LOCAL_PRIVATE_INSTRUCTION_7B3F"
        model.promptText = "Разбери почту за сегодня. \(privateInstruction)"
        model.submitPrompt()
        try await waitForPrompt(model)
        #expect(model.error == nil)
        #expect(client.calls.contains { $0.1["name"]?.stringValue == "list_messages" && $0.1["arguments"]?["period"]?.stringValue == "today" })
        let user = try #require(model.selectedChat.messages.first { $0.role == .user })
        #expect(user.contextContent.contains("Body 1"))
        #expect(user.contextContent.contains("reference material"))
        #expect(!user.contextContent.contains("never-pass-password-to-model"))
        #expect(user.content.contains("Почта: Exchange · сегодня · Inbox · 2 писем"))
        #expect(model.outputText.contains("Body 1"))
        // Only retrieval parameters may leave the chat path for the connector.
        // The full user request, received message bodies and authentication
        // secrets must not be echoed into subsequent MCP tool requests.
        #expect(user.contextContent.contains(privateInstruction))
        func assertRetrievalRequestsContainNoContent() throws {
            for (_, parameters) in client.calls {
                let serialized = String(decoding: try JSONEncoder().encode(parameters), as: UTF8.self)
                #expect(!serialized.contains(privateInstruction))
                #expect(!serialized.contains("Разбери почту"))
                #expect(!serialized.contains("Body 0") && !serialized.contains("Body 1"))
                #expect(!serialized.contains("never-pass-password-to-model"))
            }
        }
        try assertRetrievalRequestsContainNoContent()
        model.promptText = "А за неделю?"
        model.submitPrompt(); try await waitForPrompt(model)
        #expect(model.error == nil)
        #expect(client.calls.last { $0.1["name"]?.stringValue == "list_messages" }?.1["arguments"]?["period"]?.stringValue == "this_week")
        try assertRetrievalRequestsContainNoContent()
        let before = client.calls.count
        model.promptText = "Составь план на сегодня"
        model.submitPrompt(); try await waitForPrompt(model)
        #expect(model.error == nil)
        #expect(client.calls.count == before)
    }

    @Test func promptAuthenticationFailurePreservesDraftAndCanRetry() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(); client.authenticationFails = true; client.mailCount = 1
        let value = profile(), manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "test")); defer { manager.stopAll() }
        let model = promptModel(store, provider: AppMCPPromptContextProvider(manager: manager))
        let prompt = "Покажи письма за вчера"
        model.promptText = prompt; model.submitPrompt(); try await waitForPrompt(model)
        #expect(model.error != nil)
        #expect(model.selectedChat.messages.isEmpty)
        #expect(model.promptText == prompt)
        #expect(model.conversation.canSend)
        #expect(model.externalContextProgress == nil)
        client.authenticationFails = false
        model.submitPrompt(); try await waitForPrompt(model)
        #expect(model.error == nil)
        #expect(model.selectedChat.messages.count == 2)
    }

    @Test func cancellingMailReadDoesNotGenerateAndKeepsRequest() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(); client.mailDelay = .seconds(30)
        let value = profile(), manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        try manager.save(value, credentials: .init(password: "test")); defer { manager.stopAll() }
        let model = promptModel(store, provider: AppMCPPromptContextProvider(manager: manager))
        model.promptText = "Почта за неделю"; model.submitPrompt()
        for _ in 0..<100 {
            if client.calls.contains(where: { $0.1["name"]?.stringValue == "list_messages" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.externalContextProgress != nil)
        #expect(!model.canSubmitPrompt)
        model.cancel(); try await waitForPrompt(model)
        #expect(model.selectedChat.messages.isEmpty)
        #expect(model.promptText == "Почта за неделю")
        #expect(model.conversation.canSend)
        #expect(model.externalContextProgress == nil)
    }

    @Test func draftingDoesNotRequireAMailAccount() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient()
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        let provider = AppMCPPromptContextProvider(manager: manager)
        let result = try await provider.prepare(
            prompt: "помоги написать официально текст письма:\nКоллеги, добрый день!\nС сегодняшнего дня прошу добавлять Антона для проверки соответствия архитектурным требованиям.",
            recentUserPrompts: ["Разбери почту за сегодня"],
            progress: { _ in Issue.record("Drafting must not start mailbox access") })
        #expect(result == nil)
        #expect(client.calls.isEmpty)
    }

    @Test func mailWordsDoNotBlockOrdinaryChatWithoutExchange() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(), manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        var local = AppMCPProfile(kind: .stdio)
        local.name = "Local tools"; local.executable = "/test/local-mcp"
        try manager.save(local, credentials: .init())
        let model = promptModel(store, provider: AppMCPPromptContextProvider(manager: manager))
        model.promptText = "Почта за сегодня"

        model.submitPrompt(); try await waitForPrompt(model)

        #expect(model.error == nil)
        #expect(model.selectedChat.messages.count == 2)
        #expect(model.selectedChat.messages.first?.content == "Почта за сегодня")
        #expect(model.outputText.hasPrefix("Answer"))
        #expect(client.calls.isEmpty)
    }

    @Test func promptRequiresAnUnambiguousEnabledExchangeAccount() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let client = MCPTestClient(); client.mailCount = 0
        let manager = AppMCPManager(store: store, secrets: MCPTestSecrets(), factory: { client })
        let provider = AppMCPPromptContextProvider(manager: manager)
        #expect(try await provider.prepare(prompt: "Почта за сегодня", recentUserPrompts: [], progress: { _ in }) == nil)
        var work = profile(); work.name = "Рабочий ящик"
        var other = profile(); other.name = "Другой ящик"
        try manager.save(work, credentials: .init(password: "test"))
        try manager.save(other, credentials: .init(password: "test")); defer { manager.stopAll() }
        await #expect(throws: AppMCPError.self) { try await provider.prepare(prompt: "Почта за сегодня", recentUserPrompts: [], progress: { _ in }) }
        #expect(client.calls.isEmpty)
        let result = try await provider.prepare(prompt: "Почта за сегодня, Рабочий ящик", recentUserPrompts: [], progress: { _ in })
        #expect(result?.summary.contains("Рабочий ящик") == true)
        #expect(result?.summary.contains("0 писем") == true)
        try manager.setToolEnabled("list_messages", enabled: false, id: work.id)
        let before = client.calls.count
        await #expect(throws: AppMCPError.self) { try await provider.prepare(prompt: "Почта за сегодня, Рабочий ящик", recentUserPrompts: [], progress: { _ in }) }
        #expect(client.calls.count == before)
    }

    @Test func largeMailContextFitsBeforeInferenceAndDisclosesTruncation() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let model = promptModel(store, provider: MCPLargeContextProvider(), client: MCPContextPreparingClient())
        model.promptText = "Разбери почту за неделю"
        model.submitPrompt(); try await waitForPrompt(model)
        #expect(model.error == nil)
        let user = try #require(model.selectedChat.messages.first { $0.role == .user })
        #expect(user.contextContent.count <= 2_000)
        #expect(user.contextContent.contains("Fixture mail body"))
        #expect(user.contextContent.contains("was truncated"))
        #expect(user.content.contains("не поместилась в контекст"))
    }

    private func promptModel(_ store: AppMCPProfileStore, provider: any AppPromptContextProviding,
                             client: any AppInferenceClient = MockInferenceClient(response: "Answer", tokenDelayNanos: 1)) -> AppModel {
        let directory = store.fileURL.deletingLastPathComponent()
        let model = AppModel(modelDirectory: directory, client: client)
        model.loadState = .ready(modelDirectory: directory, loadSeconds: 0)
        model.promptContextProvider = provider
        return model
    }

    private func waitForPrompt(_ model: AppModel) async throws {
        for _ in 0..<300 {
            if !model.isTurnInFlight { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Prompt did not finish")
        model.cancel()
    }

    @Test func stdioRoundTripAndDisconnectCancelPendingRequests() async throws {
        let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let script = store.fileURL.deletingLastPathComponent().appendingPathComponent("server.py")
        try """
        import sys, json
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request or request.get('method') == 'wait':
                continue
            result = {'tools': []}
            if request['method'] == 'initialize':
                result = {'protocolVersion': request['params']['protocolVersion'], 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'test', 'version': '1'}}
            sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}) + '\\n')
            sys.stdout.flush()
        """.write(to: script, atomically: true, encoding: .utf8)
        let client = AppMCPStdioClient(timeout: .seconds(3))
        try await client.start(executable: "/usr/bin/python3", arguments: [script.path], directory: "", environment: [:])
        let result = try await client.request("tools/list", params: .object([:]))
        #expect(result["tools"]?.arrayValue == [])
        let pending = Task { try await client.request("wait", params: .object([:])) }
        try await Task.sleep(for: .milliseconds(30))
        client.stop()
        await #expect(throws: AppMCPError.self) { try await pending.value }
    }
}
#endif
