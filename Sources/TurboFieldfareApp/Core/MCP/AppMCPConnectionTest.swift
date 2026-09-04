#if os(macOS)
import Foundation
import Observation

public enum AppMCPTestInput {
    public static func json(_ value: AppMCPValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }

    public static func template(tool: AppMCPTool, kind: AppMCPKind, period: String = "today") -> String {
        if kind == .exchange && tool.name == "list_messages" {
            return json(.object(["period": .string(period), "folder": .string("Inbox"),
                                 "page_size": .number(3), "include_body": .bool(false)]))
        }
        let required = Set(tool.schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        var values: [String: AppMCPValue] = [:]
        for (name, schema) in tool.schema["properties"]?.objectValue ?? [:] {
            if let value = schema["default"] { values[name] = value }
            else if required.contains(name) {
                if let value = schema["enum"]?.arrayValue?.first { values[name] = value }
                else {
                    switch schema["type"]?.stringValue {
                    case "boolean": values[name] = .bool(false)
                    case "integer", "number": values[name] = schema["minimum"] ?? .number(0)
                    case "object": values[name] = .object([:])
                    case "array": values[name] = .array([])
                    default: values[name] = .string("")
                    }
                }
            }
        }
        return json(.object(values))
    }

    public static func parse(_ text: String, tool: AppMCPTool) throws -> AppMCPValue {
        guard let value = try? JSONDecoder().decode(AppMCPValue.self, from: Data(text.utf8)),
              let object = value.objectValue else {
            throw AppMCPError.configuration("Enter valid JSON arguments enclosed in { }.")
        }
        let required = tool.schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let missing = required.filter { object[$0] == nil }
        guard missing.isEmpty else {
            throw AppMCPError.configuration("Required parameters: \(missing.joined(separator: ", ")).")
        }
        // The server validates its complete JSON Schema, including nested/union types.
        return value
    }
}

public struct AppMCPTestResult: Sendable {
    public let tool: String
    public let arguments: AppMCPValue
    public let response: AppMCPValue
    public let receivedAt: Date
    public let elapsed: TimeInterval
    public var isError: Bool { response["isError"]?.boolValue == true }
    public var json: String { AppMCPTestInput.json(response) }
    public var byteCount: Int { (try? JSONEncoder().encode(response).count) ?? 0 }
    public var summary: String {
        if isError { return "The tool returned an error. See the server response below." }
        let structured = response["structuredContent"]
        for key in ["messages", "events", "items", "results"] {
            if let items = structured?[key]?.arrayValue {
                if items.isEmpty { return "Response received · 0 \(key). Try another period or filter." }
                let label = items.count == 1 ? String(key.dropLast()) : key
                return "Response received · \(items.count) \(label) in this response."
            }
        }
        if structured == .object([:]) || structured == .array([]) || structured == .null ||
            (structured == nil && response["content"]?.arrayValue?.isEmpty == true) {
            return "Response received · empty result."
        }
        return "Response received. Inspect the returned data below."
    }
}

/// Ephemeral diagnostics only: no model, chat attachment, file log or Keychain write.
@MainActor
@Observable
public final class AppMCPConnectionTest {
    public private(set) var isRunning = false
    public private(set) var result: AppMCPTestResult?
    public private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    public init() {}

    public func start(manager: AppMCPManager, id: UUID, tool: AppMCPTool, argumentsJSON: String) {
        guard !isRunning else { return }
        clear()
        let arguments: AppMCPValue
        do { arguments = try AppMCPTestInput.parse(argumentsJSON, tool: tool) }
        catch { self.error = error.localizedDescription; return }
        let current = generation
        isRunning = true
        task = Task { [weak self] in
            let clock = ContinuousClock(), started = ContinuousClock.now
            do {
                let response = try await manager.callRaw(id, tool: tool.name, arguments: arguments)
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                let duration = started.duration(to: clock.now).components
                self.result = AppMCPTestResult(tool: tool.name, arguments: arguments, response: response,
                    receivedAt: Date(), elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            } catch {
                guard let self, self.generation == current else { return }
                self.error = error is CancellationError ? "Request cancelled." : error.localizedDescription
            }
            guard let self, self.generation == current else { return }
            self.isRunning = false; self.task = nil
        }
    }
    public func cancel() {
        let wasRunning = isRunning
        clear()
        if wasRunning { error = "Request cancelled. The server may already have processed the request." }
    }
    public func clear() {
        generation = UUID(); task?.cancel(); task = nil
        isRunning = false; result = nil; error = nil
    }
}
#endif
