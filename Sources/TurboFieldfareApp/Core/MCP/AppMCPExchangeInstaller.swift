#if os(macOS)
import Foundation

public struct AppMCPPythonInfo: Decodable, Equatable, Sendable {
    public let executable: String
    public let version: String
    let major: Int
    let minor: Int
    let hasVenv: Bool
    let hasEnsurepip: Bool

    public var compatibilityIssue: String? {
        if major != 3 || minor < 10 { return "Python \(version) is too old. Python 3.10 or newer is required." }
        if !hasVenv || !hasEnsurepip { return "Python \(version) runs, but venv or ensurepip is missing. Choose a complete Python installation." }
        return nil
    }
}

@MainActor
public final class AppMCPExchangeInstaller {
    private let runner = AppMCPSetupProcess()
    private let destination: URL
    public init(directory: URL? = nil) {
        destination = directory ?? Self.installedExecutable
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    public static var installedExecutable: URL {
        AppMCPProfileStore.applicationDirectory.appendingPathComponent("MCP/exchange-0.2.0/.venv/bin/exchange-mcp")
    }
    public static var suggestedPython: String {
        ["/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3", "/usr/local/bin/python3.13", "/usr/local/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    public static func normalizedPythonPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    /// No package downloads or mailbox access: checks the selected interpreter itself.
    public func checkPython(_ path: String, diagnostics: AppMCPDiagnostics) async throws -> AppMCPPythonInfo {
        diagnostics.begin("Check Python")
        let info = try await inspectPython(path)
        if let issue = info.compatibilityIssue { throw AppMCPError.configuration(issue + "\n" + info.executable) }
        diagnostics.complete("Python \(info.version) · venv and ensurepip available\n\(info.executable)")
        return info
    }

    func inspectPython(_ path: String, timeout: Duration = .seconds(15)) async throws -> AppMCPPythonInfo {
        let python = Self.normalizedPythonPath(path)
        guard python.hasPrefix("/") else {
            throw AppMCPError.configuration("Choose the Python executable using its full path, for example /opt/homebrew/bin/python3.13. A folder or the command name python3 is not enough.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: python, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: python) else {
            throw AppMCPError.configuration("Python was not found or cannot be executed at:\n\(python)\nChoose the python3 file, not its folder.")
        }
        let output = try await runner.run(python, ["-I", "-c", """
        import importlib.util, json, sys
        print(json.dumps(dict(executable=sys.executable, version=sys.version.split()[0],
            major=sys.version_info.major, minor=sys.version_info.minor,
            hasVenv=importlib.util.find_spec('venv') is not None,
            hasEnsurepip=importlib.util.find_spec('ensurepip') is not None)))
        """], directory: nil, stage: "Python check", timeout: timeout)
        guard let data = output.split(separator: "\n").last?.data(using: .utf8),
              let info = try? JSONDecoder().decode(AppMCPPythonInfo.self, from: data) else {
            throw AppMCPDiagnosticText.failure("The selected program did not return valid Python version information.", details: output)
        }
        return info
    }

    public func install(python: String, diagnostics: AppMCPDiagnostics = AppMCPDiagnostics(),
                        checked: @MainActor (AppMCPPythonInfo) -> Void = { _ in }) async throws -> String {
        let info = try await checkPython(python, diagnostics: diagnostics)
        checked(info)
        diagnostics.begin("Prepare connector files")
        guard let resources = Bundle.module.url(forResource: "ExchangeMCP", withExtension: nil) else {
            throw AppMCPError.configuration("The bundled Exchange connector is missing. Rebuild the app.")
        }
        // Use the final path from the start: venv scripts contain absolute interpreter paths.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent(".ready")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        for name in ["exchange_mcp", "pyproject.toml", "requirements.lock"] {
            let target = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: target)
        }
        diagnostics.complete(destination.path)
        diagnostics.begin("Create Python environment")
        let environment = destination.appendingPathComponent(".venv")
        // A repair must use the newly selected Python, not leave old venv symlinks behind.
        let selected = URL(fileURLWithPath: Self.normalizedPythonPath(python)).standardizedFileURL.path
        guard !selected.hasPrefix(environment.standardizedFileURL.path + "/") else {
            throw AppMCPError.configuration("Choose a base Python installation outside the connector's .venv before repairing it.")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: environment.path),
           attributes[.type] as? FileAttributeType != .typeDirectory {
            throw AppMCPError.configuration("The connector environment path is not a regular directory: \(environment.path)")
        }
        _ = try await runner.run(Self.normalizedPythonPath(python), ["-m", "venv", "--clear", ".venv"],
                                 directory: destination, stage: "Creating the Python environment")
        diagnostics.complete("Created .venv using Python \(info.version).")
        let venvPython = destination.appendingPathComponent(".venv/bin/python").path
        diagnostics.begin("Install Python dependencies")
        let packages = try await runner.run(venvPython,
            ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "-r", "requirements.lock"],
            directory: destination, stage: "Installing Python dependencies")
        diagnostics.complete(packages)
        diagnostics.begin("Install Exchange connector")
        let installation = try await runner.run(venvPython,
            ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--no-deps", "."],
            directory: destination, stage: "Installing the Exchange connector")
        diagnostics.complete(installation)
        diagnostics.begin("Verify connector environment")
        _ = try await runner.run(venvPython, ["-c", "import exchangelib, mcp, exchange_mcp.server"],
                                 directory: destination, stage: "Importing connector dependencies", timeout: .seconds(30))
        _ = try await runner.run(venvPython, ["-m", "pip", "check", "--disable-pip-version-check"],
                                 directory: destination, stage: "Checking dependency compatibility", timeout: .seconds(30))
        let executable = destination.appendingPathComponent(".venv/bin/exchange-mcp").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AppMCPError.configuration("Dependencies are installed, but the exchange-mcp executable is missing: \(executable)")
        }
        try Data("0.2.0\n".utf8).write(to: marker, options: .atomic)
        diagnostics.complete("Connector and dependencies are ready. Choose Connect & Verify to check Exchange access.")
        return executable
    }

    public func cancel() { runner.cancel() }
}
#endif
