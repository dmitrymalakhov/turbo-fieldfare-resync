import Darwin
import Foundation
import Synchronization
import TurboFieldfareAppCore

/// Starts exactly one server owned by this app. Preflight happens before the
/// 26B model is opened, so a busy port or another model process does not turn
/// into an expensive second load that only fails at bind time.
@MainActor
final class ProcessLocalServerClient: AppLocalServerClient {
    private final class ReadinessBuffer: Sendable {
        struct State: Sendable {
            var text = ""
            var reported = false
        }

        let state = Mutex(State())
    }

    private var process: Process?
    private var standardOutput: Pipe?
    private var standardError: Pipe?

    func start(
        configuration: AppLocalServerConfiguration,
        onEvent: @escaping @MainActor @Sendable (AppLocalServerEvent) -> Void
    ) throws {
        guard process == nil else {
            throw Self.failure("This app already owns a server process.")
        }
        try Self.ensurePortIsAvailable(configuration.port)
        try Self.ensureNoConflictingModelProcesses()

        let executable = try Self.serverExecutableURL()
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let readiness = ReadinessBuffer()
        process.executableURL = executable
        process.arguments = Self.arguments(for: configuration)
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            let becameReady = readiness.state.withLock { state -> Bool in
                guard !state.reported else { return false }
                state.text += text
                if state.text.count > 4_096 {
                    state.text = String(state.text.suffix(2_048))
                }
                guard state.text.contains("TurboFieldfareServer is ready") else {
                    return false
                }
                state.reported = true
                return true
            }
            Task { @MainActor in
                onEvent(.output(text))
                if becameReady { onEvent(.ready) }
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in onEvent(.output(text)) }
        }
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { @MainActor [weak self] in
                self?.finishProcess(terminated)
                onEvent(.terminated(exitCode: status))
            }
        }

        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
        do {
            try process.run()
        } catch {
            finishProcess(process)
            throw error
        }
        onEvent(.launched(processIdentifier: process.processIdentifier))
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func finishProcess(_ candidate: Process) {
        guard process === candidate else { return }
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        standardOutput = nil
        standardError = nil
        process = nil
    }

    private static func arguments(
        for configuration: AppLocalServerConfiguration
    ) -> [String] {
        let options = configuration.runtimeOptions
        return [
            "--model", configuration.modelDirectory.path,
            "--port", String(configuration.port),
            "--max-context", String(configuration.maxContextTokens),
            "--expert-cache-slots", String(options.expertCacheSlots),
            "--expert-cache-policy", options.expertCachePolicy.rawValue,
            "--prefill", options.prefillEnabled ? "on" : "off",
            "--prefill-chunk-tokens", String(options.prefillChunkTokens),
            "--rdadvise", options.rdadvisePolicy.rawValue,
            "--vision-residency", options.visionResidencyPolicy.rawValue,
        ]
    }

    private static func serverExecutableURL() throws -> URL {
        guard let appExecutable = Bundle.main.executableURL else {
            throw failure("The app executable location is unavailable.")
        }
        let executableDirectory = appExecutable.deletingLastPathComponent()
        let candidates = [
            executableDirectory.appendingPathComponent("TurboFieldfareServer"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/TurboFieldfareServer"),
        ]
        if let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw failure(
            "TurboFieldfareServer is missing beside the app. Run swift build -c release before launching TurboFieldfareMac.")
    }

    private static func ensurePortIsAvailable(_ port: Int) throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        probe.arguments = ["-G", "1", "-z", "127.0.0.1", String(port)]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus != 0 else {
            throw failure(
                "Port \(port) is already in use. The app will not replace or stop that process.")
        }
    }

    private static func ensureNoConflictingModelProcesses() throws {
        let pattern = "TurboFieldfareServer|TurboFieldfareMac|"
            + "TurboFieldfareDecodeService|TurboFieldfareCLI|"
            + "TurboFieldfarePackageTests|swiftpm-testing-helper|mlx_lm|mlx-lm"
        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        probe.arguments = ["-fl", pattern]
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else {
            // pgrep uses 1 for a clean "no matches" result.
            if probe.terminationStatus == 1 { return }
            throw failure("Could not check for another model process.")
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let listing = String(data: data, encoding: .utf8) ?? ""
        let ownPID = String(getpid())
        let ownDecodeLabel = ".decode.\(getuid()).\(getpid())."
        let conflicts = listing.split(separator: "\n").map(String.init).filter { line in
            let pid = line.split(separator: " ", maxSplits: 1).first.map(String.init)
            if pid == ownPID { return false }
            if line.contains("TurboFieldfareDecodeService"),
               line.contains(ownDecodeLabel) { return false }
            return true
        }
        guard conflicts.isEmpty else {
            let detail = conflicts.prefix(3).joined(separator: "\n")
            throw failure(
                "Another model process is running. Stop it yourself before starting the server:\n\(detail)")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "TurboFieldfare.LocalServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
