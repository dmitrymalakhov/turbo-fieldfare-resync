#if os(macOS)
import Foundation

@MainActor
public final class AppMCPExchangeInstaller {
    private var process: Process?
    private var continuation: CheckedContinuation<Void, Error>?
    public init() {}
    public static var installedExecutable: URL {
        AppMCPProfileStore.applicationDirectory.appendingPathComponent("MCP/exchange-0.2.0/.venv/bin/exchange-mcp")
    }
    public static var suggestedPython: String {
        ["/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3", "/usr/local/bin/python3.13", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    public func install(python: String) async throws -> String {
        let destination = Self.installedExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let marker = destination.appendingPathComponent(".ready")
        if FileManager.default.fileExists(atPath: marker.path),
           FileManager.default.isExecutableFile(atPath: Self.installedExecutable.path) { return Self.installedExecutable.path }
        guard process == nil, FileManager.default.isExecutableFile(atPath: python) else {
            throw AppMCPError.configuration("Choose Python 3.10 or newer to install the Exchange connector.")
        }
        guard let resources = Bundle.module.url(forResource: "ExchangeMCP", withExtension: nil) else {
            throw AppMCPError.configuration("The bundled Exchange connector is missing. Rebuild the app.")
        }
        // Use the final path from the start: venv scripts contain absolute interpreter paths.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["exchange_mcp", "pyproject.toml", "requirements.lock"] {
            let target = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: target)
        }
        try await run(python, ["-c", "import sys; assert sys.version_info >= (3,10), 'Python 3.10 or newer is required'"], directory: destination)
        try await run(python, ["-m", "venv", ".venv"], directory: destination)
        let venvPython = destination.appendingPathComponent(".venv/bin/python").path
        try await run(venvPython, ["-m", "pip", "install", "--disable-pip-version-check", "-r", "requirements.lock"], directory: destination)
        try await run(venvPython, ["-m", "pip", "install", "--disable-pip-version-check", "--no-deps", "."], directory: destination)
        try Data("0.2.0\n".utf8).write(to: marker, options: .atomic)
        return Self.installedExecutable.path
    }

    private func run(_ executable: String, _ arguments: [String], directory: URL) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
                p.currentDirectoryURL = directory; p.environment = AppMCPStdioClient.baseEnvironment
                p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                p.terminationHandler = { [weak self] terminated in
                    let code = terminated.terminationStatus
                    Task { @MainActor [weak self] in
                        guard let self, self.process === terminated else { return }
                        self.process = nil
                        let completion = self.continuation; self.continuation = nil
                        if code == 0 { completion?.resume() }
                        else { completion?.resume(throwing: AppMCPError.configuration("Connector installation failed (exit \(code)). Check Python 3.10+, internet access and your corporate package proxy, then retry.")) }
                    }
                }
                process = p; continuation = c
                do { try p.run() } catch { process = nil; continuation = nil; c.resume(throwing: error) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    public func cancel() {
        if let p = process { p.terminationHandler = nil; if p.isRunning { p.terminate() } }
        process = nil
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
}
#endif
