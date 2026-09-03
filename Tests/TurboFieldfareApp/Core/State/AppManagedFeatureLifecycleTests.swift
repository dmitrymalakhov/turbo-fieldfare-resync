import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite struct AppManagedFeatureLifecycleTests {
    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    @Test func enablingVisionUnloadsALiveModelBeforeDownloading() async throws {
        let directory = try makeCompleteModelInstall("managed-vision")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = MockLifecycleInferenceClient()
        lifecycle.suspendUnloads = true
        let vision = MockVisionPackInstallerClient(
            events: [.checking], holdOpen: true)
        let model = AppModel(
            modelDirectory: directory,
            client: lifecycle,
            visionInstaller: vision)
        model.applyLoadState(.ready(
            modelDirectory: directory,
            loadSeconds: 0))

        model.enableVisionPack()
        await lifecycle.waitForUnloadStart()

        #expect(model.isPreparingVisionSupport)
        #expect(!model.isInstallingVisionPack)
        lifecycle.releaseUnloads()
        await waitUntil { model.isInstallingVisionPack }
        #expect(!model.isPreparingVisionSupport)
        model.cancelVisionInstall()
    }

    @MainActor
    @Test func enablingVisionActivatesThenRestoresALiveModel() async throws {
        let directory = try makeCompleteModelInstall("managed-vision-activation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = MockLifecycleInferenceClient()
        let vision = MockVisionPackInstallerClient(
            events: [.readyToActivate(directory)],
            activationAction: { textModel in
                try installVisionCompanion(forTextModel: textModel)
            })
        let model = AppModel(
            modelDirectory: directory,
            client: lifecycle,
            visionInstaller: vision)
        model.applyLoadState(.ready(
            modelDirectory: directory,
            loadSeconds: 0))

        model.enableVisionPack()
        await lifecycle.waitForLoadStart()

        #expect(vision.activationCount == 1)
        #expect(model.isVisionPackInstalled)
        #expect(lifecycle.ensureLoadedCallCount() == 1)
    }

    @MainActor
    @Test func preparedVisionPackCanBeEnabledWithoutAManualUnload() async throws {
        let directory = try makeCompleteModelInstall("managed-vision-prepared")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = MockLifecycleInferenceClient()
        let vision = MockVisionPackInstallerClient(
            preparedValid: true,
            activationAction: { textModel in
                try installVisionCompanion(forTextModel: textModel)
            })
        let model = AppModel(
            modelDirectory: directory,
            client: lifecycle,
            visionInstaller: vision)
        model.applyLoadState(.ready(
            modelDirectory: directory,
            loadSeconds: 0))

        model.enableVisionPack()
        await lifecycle.waitForLoadStart()

        #expect(vision.activationCount == 1)
        #expect(model.isVisionPackInstalled)
        #expect(lifecycle.ensureLoadedCallCount() == 1)
    }

    @MainActor
    @Test func serverTakesModelOnlyAfterUnloadAndRestoresItAfterStop() async throws {
        let directory = try makeCompleteModelInstall("managed-server")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = MockLifecycleInferenceClient()
        lifecycle.suspendUnloads = true
        let server = MockLocalServerClient()
        let model = AppModel(
            modelDirectory: directory,
            client: lifecycle,
            localServerClient: server)
        model.applyLoadState(.ready(
            modelDirectory: directory,
            loadSeconds: 0))

        model.startLocalServer()
        await lifecycle.waitForUnloadStart()
        #expect(model.localServerState == .waitingForModelUnload)
        #expect(server.configurations.isEmpty)

        lifecycle.releaseUnloads()
        await waitUntil { server.configurations.count == 1 }
        #expect(model.localServerState == .starting)
        #expect(server.configurations.first?.modelDirectory.path
            == directory.standardizedFileURL.path)
        #expect(!model.canLoadModel)

        server.emit(.ready)
        #expect(model.localServerState == .running)
        model.stopLocalServer()
        #expect(model.localServerState == .stopping)
        #expect(server.stopCount == 1)
        server.emit(.terminated(exitCode: 0))

        await lifecycle.waitForLoadStart()
        #expect(lifecycle.ensureLoadedCallCount() == 1)
    }

    @MainActor
    @Test func stoppingServerStartedFromUnloadedStateDoesNotLoadTheAppModel() async throws {
        let directory = try makeCompleteModelInstall("managed-server-unloaded")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = MockLifecycleInferenceClient()
        let server = MockLocalServerClient()
        let model = AppModel(
            modelDirectory: directory,
            client: lifecycle,
            localServerClient: server)

        model.startLocalServer()
        server.emit(.ready)
        model.stopLocalServer()
        server.emit(.terminated(exitCode: 0))
        await Task.yield()

        #expect(model.localServerState == .stopped)
        #expect(lifecycle.ensureLoadedCallCount() == 0)
    }

    @MainActor
    @Test func failedServerStartRestoresThePreviouslyLoadedAppModel() async throws {
        let directory = try makeCompleteModelInstall("managed-server-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lifecycle = MockLifecycleInferenceClient()
        let server = MockLocalServerClient()
        server.startError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "port is occupied"])
        let model = AppModel(
            modelDirectory: directory,
            client: lifecycle,
            localServerClient: server)
        model.applyLoadState(.ready(
            modelDirectory: directory,
            loadSeconds: 0))

        model.startLocalServer()
        await lifecycle.waitForLoadStart()

        #expect(model.localServerState == .failed("port is occupied"))
        #expect(lifecycle.ensureLoadedCallCount() == 1)
    }
}
