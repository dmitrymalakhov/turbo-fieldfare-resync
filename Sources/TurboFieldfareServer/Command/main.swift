import Darwin
import Foundation
import TurboFieldfare
import TurboFieldfareServerCore

let arguments: ServerArguments
let runtimeConfiguration: RuntimeConfiguration
do {
    arguments = try ServerArguments.parse(Array(CommandLine.arguments.dropFirst()))
    // Resolved here so an unusable flag combination exits with usage instead of
    // failing after the model has started loading.
    runtimeConfiguration = try arguments.resolvedRuntimeConfiguration()
} catch ServerArgumentError.help {
    print(ServerArguments.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(ServerArguments.usage)\n".utf8))
    exit(2)
}

do {
    let signals = ServerTerminationSignals()
    let modelURL = URL(fileURLWithPath: arguments.model).standardizedFileURL
    FileHandle.standardError.write(Data(
        "Loading \(arguments.modelID) from \(modelURL.path)…\n".utf8))
    let backend = try await ServerModelSession.load(
        modelDirectory: modelURL,
        maxContext: arguments.maxContext,
        promptCacheMode: arguments.promptCacheMode,
        runtimeConfiguration: runtimeConfiguration)
    let server = TurboFieldfareHTTPServer(
        modelID: arguments.modelID,
        queueLimit: arguments.queueLimit,
        backend: backend)
    _ = try await server.start(port: arguments.port)
    let baseURL = "http://127.0.0.1:\(arguments.port)"
    print("""
    TurboFieldfareServer is ready
      Base URL:  \(baseURL)/v1
      Health:    \(baseURL)/health
      Model:     \(arguments.modelID)
      Context:   \(arguments.maxContext) tokens
      Cache:     \(arguments.promptCacheMode.rawValue)

    OpenAI-compatible clients can use any local API key and \(baseURL)/v1.
    Press Control-C to stop the server.
    """)

    _ = await signals.wait()
    try await server.shutdown()
    await signals.cancel()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
