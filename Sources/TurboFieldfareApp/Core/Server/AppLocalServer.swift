import Foundation

/// The subset of app settings that the standalone OpenAI-compatible server
/// needs at launch. Keeping this in AppCore lets AppModel own the lifecycle
/// without making the cross-platform core depend on Process or AppKit.
public struct AppLocalServerConfiguration: Equatable, Sendable {
    public var modelDirectory: URL
    public var port: Int
    public var maxContextTokens: Int
    public var runtimeOptions: AppRuntimeOptions

    public init(
        modelDirectory: URL,
        port: Int = 8_080,
        maxContextTokens: Int,
        runtimeOptions: AppRuntimeOptions
    ) {
        self.modelDirectory = modelDirectory.standardizedFileURL
        self.port = port
        self.maxContextTokens = maxContextTokens
        self.runtimeOptions = runtimeOptions
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1")!
    }
}

public enum AppLocalServerEvent: Equatable, Sendable {
    case launched(processIdentifier: Int32)
    case output(String)
    case ready
    case terminated(exitCode: Int32)
}

/// Process ownership lives behind this boundary. The Mac implementation only
/// ever stops the Process instance it launched, while tests can drive the same
/// AppModel state machine without starting a model process.
@MainActor
public protocol AppLocalServerClient: AnyObject {
    func start(
        configuration: AppLocalServerConfiguration,
        onEvent: @escaping @MainActor @Sendable (AppLocalServerEvent) -> Void
    ) throws
    func stop()
}

public enum AppLocalServerState: Equatable, Sendable {
    case stopped
    case waitingForModelUnload
    case starting
    case running
    case stopping
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .waitingForModelUnload, .starting, .running, .stopping:
            true
        case .stopped, .failed:
            false
        }
    }
}
