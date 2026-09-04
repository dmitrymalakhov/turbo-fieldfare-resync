#if os(macOS)
import Foundation

@MainActor
public protocol AppMCPClient: AnyObject {
    var onDisconnect: (@MainActor () -> Void)? { get set }
    var onStage: (@MainActor (String) -> Void)? { get set }
    var lastFailure: String? { get }
    func start(executable: String, arguments: [String], directory: String, environment: [String: String]) async throws
    func request(_ method: String, params: AppMCPValue) async throws -> AppMCPValue
    func stop()
}

public extension AppMCPClient {
    var onStage: (@MainActor (String) -> Void)? { get { nil } set {} }
    var lastFailure: String? { nil }
}

/// A local stdio client. No shell expansion, inherited credentials, or model callbacks.
@MainActor
public final class AppMCPStdioClient: AppMCPClient {
    public var onDisconnect: (@MainActor () -> Void)?
    public var onStage: (@MainActor (String) -> Void)?
    public private(set) var lastFailure: String?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var buffer = Data()
    private var nextID = 0
    private var stderrBuffer = AppMCPDiagnosticBuffer()
    private var stderrEnded = false
    private var exitStatus: Int32?
    private var secretValues: [String] = []
    private var executablePath = ""
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<AppMCPValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var closeTask: Task<Void, Never>?
    private let writeQueue = DispatchQueue(label: "TurboFieldfare.MCP.stdin")
    private let timeout: Duration
    public init(timeout: Duration = .seconds(30)) { self.timeout = timeout }

    public func start(executable: String, arguments: [String], directory: String,
                      environment: [String: String]) async throws {
        lastFailure = nil; stderrEnded = false; exitStatus = nil
        secretValues = Array(environment.values); executablePath = executable
        onStage?("Launch MCP process")
        guard process == nil, FileManager.default.isExecutableFile(atPath: executable) else {
            throw AppMCPError.configuration("The MCP executable is missing or cannot be run:\n\(executable)\nInstall / Repair Connector, or choose the server executable. Python alone is not an MCP server.")
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let launch = UUID(); generation = launch
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if !directory.isEmpty { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
        var env = Self.baseEnvironment
        env.merge(environment) { _, new in new }
        p.environment = env
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard self?.generation == launch else { return }
                self?.receive(data)
            }
        }
        let captured = AppMCPDiagnosticBuffer(); stderrBuffer = captured
        // Capture only bounded stderr, never protocol stdout or request parameters.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            captured.append(data)
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == launch else { return }
                    self.stderrEnded = true; self.finishTermination()
                }
            }
        }
        p.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == launch else { return }
                self.exitStatus = code; self.finishTermination()
            }
        }
        process = p; input = stdin; output = stdout; errorOutput = stderr
        do {
            try p.run()
            onStage?("MCP initialization")
            let result = try await request("initialize", params: .object([
                "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("TurboFieldfare"), "version": .string("1.0")])]))
            guard let version = result["protocolVersion"]?.stringValue,
                  ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(version),
                  result["capabilities"]?["tools"]?.objectValue != nil else {
                throw AppMCPError.protocolError
            }
            try send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        } catch {
            let failure: Error
            if error is AppMCPError || error is CancellationError { failure = error }
            else { failure = diagnosticFailure("Could not launch MCP: \(executable)", details: error.localizedDescription) }
            lastFailure = AppMCPDiagnosticText.clean(failure.localizedDescription, secrets: secretValues)
            stop(); throw failure
        }
    }

    public static var baseEnvironment: [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var result: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "PATH"] { result[key] = parent[key] }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (result["PATH"] ?? "")
        result["PYTHONUNBUFFERED"] = "1"
        return result
    }

    public func request(_ method: String, params: AppMCPValue = .object([:])) async throws -> AppMCPValue {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw AppMCPError.disconnected }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self else { return }
                    let advice = method == "initialize"
                        ? "The executable must start an MCP server over stdio. Selecting Python without the connector script or module will not work."
                        : "Check the server, VPN and network access."
                    self.cancel(id: id, error: self.diagnosticFailure("MCP \(method) timed out. \(advice)"))
                }
                do {
                    try send(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                      "method": .string(method), "params": params]))
                } catch { finish(id: id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id, error: CancellationError()) }
        }
    }

    private func cancel(id: Int, error: Error) {
        guard pending[id] != nil else { return }
        try? send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                           "params": .object(["requestId": .number(Double(id))])]))
        finish(id: id, result: .failure(error))
    }

    private func send(_ value: AppMCPValue) throws {
        guard let handle = input?.fileHandleForWriting else { throw AppMCPError.disconnected }
        var data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw AppMCPError.protocolError }
        data.append(10)
        let bytes = data
        let launch = generation
        writeQueue.async { [weak self] in
            do { try handle.write(contentsOf: bytes) }
            catch { Task { @MainActor [weak self] in
                guard self?.generation == launch else { return }
                self?.closed()
            } }
        }
    }

    private func receive(_ data: Data) {
        guard process != nil else { return }
        // Allow a short drain for the final traceback, but a server that closes
        // stdout and stays alive must not keep appearing connected indefinitely.
        guard !data.isEmpty else {
            output?.fileHandleForReading.readabilityHandler = nil
            closeTask = Task { [weak self, launch = generation] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.generation == launch else { return }
                if let process = self.process, !process.isRunning {
                    self.closed(self.diagnosticFailure("MCP process exited (code \(process.terminationStatus)).\n\(self.executablePath)"))
                } else {
                    self.closed(self.diagnosticFailure("The MCP server closed stdout. It can no longer send protocol responses."))
                }
            }
            return
        }
        buffer.append(data)
        guard buffer.count <= 8_388_608 else { failProtocol(); return }
        while let index = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<index])
            buffer.removeSubrange(...index)
            if line.isEmpty { continue }
            guard let value = try? JSONDecoder().decode(AppMCPValue.self, from: line),
                  value["jsonrpc"]?.stringValue == "2.0" else { failProtocol(); return }
            if let method = value["method"]?.stringValue {
                if let id = value["id"] {
                    let response: AppMCPValue = method == "ping"
                        ? .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
                        : .object(["jsonrpc": .string("2.0"), "id": id,
                                   "error": .object(["code": .number(-32601), "message": .string("Client capability not supported")])])
                    try? send(response)
                }
                continue
            }
            guard let id = value["id"]?.intValue else { failProtocol(); return }
            if let error = value["error"] {
                let code = error["code"]?.intValue.map { " (code \($0))" } ?? ""
                let message = error["message"]?.stringValue ?? "The server rejected the request."
                // Deliberately excludes error.data, which may echo a request or mailbox content.
                finish(id: id, result: .failure(diagnosticFailure("MCP error\(code)", details: message)))
            }
            else if let result = value["result"] { finish(id: id, result: .success(result)) }
            else { failProtocol(); return }
        }
    }

    private func finish(id: Int, result: Result<AppMCPValue, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func failProtocol() {
        closed(diagnosticFailure("Invalid MCP response. The server must write JSON-RPC to stdout and logs to stderr."))
    }
    private func diagnosticFailure(_ summary: String, details: String = "") -> AppMCPError {
        AppMCPDiagnosticText.failure(summary,
            details: [details, stderrBuffer.text].filter { !$0.isEmpty }.joined(separator: "\n"), secrets: secretValues)
    }
    private func finishTermination() {
        guard let exitStatus, stderrEnded else { return }
        closed(diagnosticFailure("MCP process exited (code \(exitStatus)).\n\(executablePath)"))
    }
    private func closed(_ error: AppMCPError? = nil) {
        guard process != nil else { return }
        let failure = error ?? diagnosticFailure("The MCP process stopped or closed its input.")
        lastFailure = failure.localizedDescription
        for id in Array(pending.keys) { finish(id: id, result: .failure(failure)) }
        let callback = onDisconnect
        stop()
        callback?()
    }
    public func stop() {
        generation = UUID()
        onDisconnect = nil; onStage = nil
        closeTask?.cancel(); closeTask = nil
        for id in Array(pending.keys) { finish(id: id, result: .failure(AppMCPError.disconnected)) }
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let p = process {
            p.terminationHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil; input = nil; output = nil; errorOutput = nil; buffer.removeAll()
    }
}
#endif
