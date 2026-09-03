import Foundation
@testable import TurboFieldfareAppCore

@MainActor
final class MockLocalServerClient: AppLocalServerClient {
    private(set) var configurations: [AppLocalServerConfiguration] = []
    private(set) var stopCount = 0
    var startError: Error?
    private var eventHandler: (@MainActor @Sendable (AppLocalServerEvent) -> Void)?

    func start(
        configuration: AppLocalServerConfiguration,
        onEvent: @escaping @MainActor @Sendable (AppLocalServerEvent) -> Void
    ) throws {
        if let startError { throw startError }
        configurations.append(configuration)
        eventHandler = onEvent
        onEvent(.launched(processIdentifier: 12_345))
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ event: AppLocalServerEvent) {
        eventHandler?(event)
    }
}
