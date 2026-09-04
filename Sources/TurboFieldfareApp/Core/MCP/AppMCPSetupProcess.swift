#if os(macOS)
import Darwin
import Foundation

@MainActor
final class AppMCPSetupProcess {
    private var process: Process?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var exitCode: Int32?
    private var outputEnded = false
    private var captured = AppMCPDiagnosticBuffer()
    private var stage = ""

    func run(_ executable: String, _ arguments: [String], directory: URL?,
             stage: String, timeout: Duration = .seconds(900)) async throws -> String {
        try Task.checkCancellation()
        guard process == nil else { throw AppMCPError.configuration("A setup command is already running.") }
        self.stage = stage
        let p = Process(), pipe = Pipe(), captured = AppMCPDiagnosticBuffer()
        self.captured = captured; exitCode = nil; outputEnded = false
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments; p.currentDirectoryURL = directory
        p.environment = AppMCPStdioClient.baseEnvironment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe; p.standardError = pipe
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; process = p
                p.terminationHandler = { [weak self] terminated in
                    let code = terminated.terminationStatus
                    Task { @MainActor [weak self] in
                        guard let self, self.process === terminated else { return }
                        self.exitCode = code; self.finishIfReady()
                    }
                }
                do {
                    try p.run()
                    // One reader preserves stdout/stderr order and completion waits for EOF.
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        let handle = pipe.fileHandleForReading
                        while true {
                            let data = handle.availableData
                            if data.isEmpty { break }
                            captured.append(data)
                        }
                        try? handle.close()
                        Task { @MainActor [weak self] in
                            guard let self, self.process === p else { return }
                            self.outputEnded = true; self.finishIfReady()
                        }
                    }
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) } catch { return }
                        guard let self, self.process === p else { return }
                        self.abort(AppMCPDiagnosticText.failure("\(stage) timed out.", details: captured.text))
                    }
                } catch {
                    finish(.failure(AppMCPDiagnosticText.failure("Could not start \(stage).",
                        details: "\(executable)\n\(error.localizedDescription)")))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    private func finishIfReady() {
        guard let exitCode, outputEnded else { return }
        if exitCode == 0 { finish(.success(captured.text)) }
        else { finish(.failure(AppMCPDiagnosticText.failure("\(stage) failed (exit \(exitCode)).", details: captured.text))) }
    }
    private func finish(_ result: Result<String, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        process?.terminationHandler = nil; process = nil
        let completion = continuation; continuation = nil
        completion?.resume(with: result)
    }
    private func abort(_ error: Error) {
        if let p = process, p.isRunning {
            p.terminate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        finish(.failure(error))
    }
    func cancel() { abort(CancellationError()) }
}
#endif
