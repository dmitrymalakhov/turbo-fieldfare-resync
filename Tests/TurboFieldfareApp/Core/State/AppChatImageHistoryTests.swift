import Darwin
import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite(.serialized) struct AppChatImageHistoryTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-image-history-\(UUID().uuidString)")
        let directory: URL
        let staging: AppImageAttachmentStore

        init() throws {
            directory = try makeCompleteModelInstall("history", parentDirectory: root)
            try installVisionCompanion(forTextModel: directory)
            staging = AppImageAttachmentStore(directoryURL: root.appendingPathComponent("staged"))
        }

        @MainActor func model() -> AppModel {
            let model = AppModel(
                modelDirectory: directory,
                client: MockInferenceClient(response: "answer", tokenDelayNanos: 1),
                attachmentStore: staging,
                settingsPersistenceEnabled: true)
            model.loadState = .ready(modelDirectory: directory, loadSeconds: 0)
            model.maxNewTokensOverride = 1
            return model
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    private func attach(_ model: AppModel, fixture: Fixture, name: String = "photo.png") async throws {
        let source = fixture.root.appendingPathComponent(name)
        try Data(name.utf8).write(to: source)
        let prior = ProcessInfo.processInfo.environment["TURBO_FIELDFARE_VISION_RUNTIME"]
        setenv("TURBO_FIELDFARE_VISION_RUNTIME", "1", 1)
        model.addImages([source])
        if let prior { setenv("TURBO_FIELDFARE_VISION_RUNTIME", prior, 1) }
        else { unsetenv("TURBO_FIELDFARE_VISION_RUNTIME") }
        for _ in 0..<1_000 where model.isAddingImages {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.isAddingImages)
        #expect(model.imageAttachmentError == nil)
    }

    @MainActor private func waitForIdle(_ model: AppModel) async throws {
        await SendWaiting.turnEnds(model)
        #expect(!model.isTurnInFlight)
    }

    @Test func legacyMessagesAndChatsDecodeWithoutImages() throws {
        let chat = AppChat(messages: [AppChatMessage(role: .user, content: "old")])
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(chat)) as? [String: Any])
        var messages = try #require(object["messages"] as? [[String: Any]])
        messages[0].removeValue(forKey: "images")
        object["messages"] = messages
        object.removeValue(forKey: "draftImages")
        let restored = try JSONDecoder().decode(
            AppChat.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.messages.first?.images == [])
        #expect(restored.draftImages == nil)
    }

    @MainActor @Test func imagesStayWithTheirMessagesAcrossTurnsChatsAndRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let originalID = model.selectedChatID
        for name in ["one.png", "two.png"] {
            try await attach(model, fixture: fixture, name: name)
            model.promptText = "Describe \(name)"
            model.run()
            try await waitForIdle(model)
            #expect(model.error == nil)
        }
        let messages = model.selectedChat.messages.filter { $0.role == .user }
        #expect(messages.map { $0.images.count } == [1, 1])
        let images = messages.flatMap { model.images(for: $0) }
        #expect(images.map(\.displayName) == ["one.png", "two.png"])
        _ = model.createChat()
        #expect(model.selectedChat.messages.isEmpty)
        model.selectChat(id: originalID)
        #expect(model.transcriptBaseMessages.filter { !$0.images.isEmpty }.count == 2)
        model.releaseAllAttachments()
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.directoryURL.path))
        for image in images {
            #expect(try Data(contentsOf: image.fileURL) == Data(image.displayName.utf8))
        }
        let restored = fixture.model()
        defer { restored.releaseAllAttachments() }
        #expect(restored.selectedChatID == originalID)
        #expect(restored.selectedChat.messages.filter { $0.role == .user } == messages)
        #expect(restored.selectedChat.messages.flatMap { restored.images(for: $0) } == images)
    }

    @MainActor @Test func branchesShareSavedImagesAndDeletionRespectsOtherOwnersAndUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        defer { model.releaseAllAttachments() }
        try await attach(model, fixture: fixture)
        model.promptText = "describe"
        model.run()
        try await waitForIdle(model)
        let sourceID = model.selectedChatID
        let message = try #require(model.selectedChat.messages.first)
        let image = try #require(model.images(for: message).first)
        let branchID = model.branchChat(from: sourceID)
        #expect(model.selectedChat.messages.first?.id != message.id)
        #expect(model.selectedChat.messages.first?.images == message.images)
        model.deleteChat(id: sourceID)
        await model.conversationDeletionTask?.value
        model.flushChatPersistence()
        #expect(FileManager.default.fileExists(atPath: image.fileURL.path))
        model.clearOutput()
        model.flushChatPersistence()
        #expect(FileManager.default.fileExists(atPath: image.fileURL.path))
        model.undoClearHistory()
        #expect(model.selectedChat.messages.first?.images == message.images)
        model.deleteChat(id: branchID)
        await model.conversationDeletionTask?.value
        model.flushChatPersistence()
        #expect(!FileManager.default.fileExists(atPath: image.fileURL.path))
    }

    @MainActor @Test func branchDraftKeepsImagesAfterRelaunchAndCanResubmitThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await attach(model, fixture: fixture)
        model.promptText = "describe"
        model.run()
        try await waitForIdle(model)
        let source = model.selectedChat
        let message = try #require(source.messages.first)
        _ = model.branchChat(from: source.id, editingMessage: message.id, replacementContent: "read text")
        #expect(model.composerImageAttachments.count == 1)
        #expect(model.selectedChat.draftImages == message.images)
        model.releaseAllAttachments()

        let restored = fixture.model()
        defer { restored.releaseAllAttachments() }
        #expect(restored.composerImageAttachments.count == 1)
        #expect(try restored.makeRequest().imageAttachments.count == 1)
        restored.run()
        try await waitForIdle(restored)
        #expect(restored.error == nil)
        #expect(restored.selectedChat.messages.first?.images.count == 1)
        #expect(restored.composerImageAttachments.isEmpty)
    }

    @MainActor @Test func missingBranchImageRefusesTheRunInsteadOfDroppingTheImage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        defer { model.releaseAllAttachments() }
        try await attach(model, fixture: fixture)
        model.promptText = "describe"
        model.run()
        try await waitForIdle(model)
        let message = try #require(model.selectedChat.messages.first)
        _ = model.branchChat(from: model.selectedChatID, throughMessage: message.id)
        let image = try #require(model.composerImageAttachments.first)
        try FileManager.default.removeItem(at: image.fileURL)
        model.run()
        await SendWaiting.turnEnds(model)
        #expect(!model.isRunning)
        #expect(model.error != nil)
        #expect(model.selectedChat.messages.isEmpty)
        #expect(model.composerImageAttachments.count == 1)
        #expect(model.conversation.canSend)
    }

    @MainActor @Test func archiveImageWriteFailureKeepsTheDraftAndDoesNotStartRecognition() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        defer { model.releaseAllAttachments() }
        try await attach(model, fixture: fixture)
        let directory = AppChatImageStore(modelDirectory: fixture.directory).directoryURL
        try Data("not a directory".utf8).write(to: directory)
        model.promptText = "describe"
        model.run()
        await SendWaiting.turnEnds(model)
        #expect(!model.isRunning)
        #expect(model.error != nil)
        #expect(model.promptText == "describe")
        #expect(model.imageAttachments.count == 1)
        #expect(model.selectedChat.messages.isEmpty)
        #expect(model.conversation.canSend)
    }

    @MainActor @Test func unsentImagesBelongToTheirOwnChat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        defer { model.releaseAllAttachments() }
        let first = model.selectedChatID
        try await attach(model, fixture: fixture)
        let images = model.imageAttachments
        let second = model.createChat()
        #expect(model.imageAttachments.isEmpty)
        model.selectChat(id: first)
        #expect(model.imageAttachments == images)
        model.selectChat(id: second)
        model.deleteChat(id: first)
        #expect(!FileManager.default.fileExists(atPath: images[0].fileURL.path))
    }

    @Test func failedBatchRollsBackItsLinksAndRejectsSymlinkSidecars() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staging = try fixture.staging.stage(data: Data("image".utf8), displayName: "../../photo.png")
        let store = AppChatImageStore(modelDirectory: fixture.directory)
        let missing = AppImageAttachment(id: UUID(), fileURL: fixture.root.appendingPathComponent("missing"),
                                         displayName: "missing", encodedBytes: 1, sha256: "bad")
        #expect(throws: (any Error).self) { try store.save([staging, missing]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
        let saved = try #require(store.save([staging]).first)
        let fileURL = store.attachment(for: saved).fileURL
        #expect(fileURL.deletingLastPathComponent() == store.directoryURL)
        fixture.staging.remove(staging)
        #expect(try Data(contentsOf: fileURL) == Data("image".utf8))
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: store.directoryURL, to: moved)
        try FileManager.default.createSymbolicLink(at: store.directoryURL, withDestinationURL: moved)
        store.remove(ids: [saved.id])
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent(fileURL.lastPathComponent).path))
        #expect(throws: (any Error).self) { try store.save([store.attachment(for: saved)]) }
    }

    @MainActor @Test func imageOnlySubmissionIsSavedAndLateImportsStayInTheirOriginalChat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        defer { model.releaseAllAttachments() }
        let originalID = model.selectedChatID
        model.addImageData(Data("image".utf8), displayName: "pasted.png")
        _ = model.createChat()
        for _ in 0..<1_000 where model.isAddingImages {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.imageAttachments.isEmpty)
        model.selectChat(id: originalID)
        #expect(model.imageAttachments.count == 1)
        #expect(model.promptText.isEmpty)
        #expect(model.canSubmitPrompt)
        model.run()
        try await waitForIdle(model)
        #expect(model.error == nil)
        #expect(model.selectedChat.messages.first?.content == "")
        #expect(model.selectedChat.messages.first?.images.count == 1)
    }

    @MainActor @Test func savedDraftCannotBeSentWithoutImageSupport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        try await attach(model, fixture: fixture)
        model.promptText = "describe"
        model.run()
        try await waitForIdle(model)
        let message = try #require(model.selectedChat.messages.first)
        _ = model.branchChat(from: model.selectedChatID, throughMessage: message.id)
        model.releaseAllAttachments()
        let unsupported = AppModel(
            modelDirectory: fixture.directory, client: MockInferenceClient(),
            attachmentStore: fixture.staging, visionRuntimeSupported: false,
            settingsPersistenceEnabled: true)
        defer { unsupported.releaseAllAttachments() }
        unsupported.loadState = .ready(modelDirectory: fixture.directory, loadSeconds: 0)
        unsupported.run()
        await SendWaiting.turnEnds(unsupported)
        #expect(unsupported.error != nil)
        #expect(!unsupported.isRunning)
        #expect(unsupported.selectedChat.messages.isEmpty)
        #expect(unsupported.composerImageAttachments.count == 1)
    }

    @MainActor @Test func copiedImageHistoryIsRebuiltWithoutAttachingOldImagesToTheNewMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        defer { model.releaseAllAttachments() }
        try await attach(model, fixture: fixture)
        model.promptText = "describe"
        model.run()
        try await waitForIdle(model)
        let source = model.selectedChat
        _ = model.branchChat(from: source.id)
        model.promptText = "what about the earlier picture?"
        let request = try model.makeRequest()
        #expect(request.imageAttachments.count == 1)
        #expect(request.messages.first?.imageIDs == request.imageAttachments.map(\.id))
        #expect(request.messages.last?.imageIDs == [])
        model.run()
        try await waitForIdle(model)
        #expect(model.error == nil)
        let users = model.selectedChat.messages.filter { $0.role == .user }
        #expect(users.map { $0.images.count } == [1, 0])
        #expect(model.composerImageAttachments.isEmpty)
    }

    @Test func cleanupWaitsForSuccessfulSaveAndNeverSweepsUncommittedImages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = try fixture.staging.stage(data: Data("image".utf8), displayName: "photo.png")
        let store = AppChatImageStore(modelDirectory: fixture.directory)
        let first = try #require(store.save([staged]).first)
        let unpublished = try #require(store.save([staged]).first)
        let original = AppChat(messages: [AppChatMessage(role: .user, content: "q", images: [first])])
        let archive = AppChatArchive(selectedChatID: original.id, chats: [original])
        let coordinator = AppChatPersistenceCoordinator()
        // Even a caller that omitted the additional undo/draft protection
        // cannot remove an image referenced by the archive being committed.
        try coordinator.flush(revision: 1, archive: archive, modelDirectory: fixture.directory,
                              retiredImageIDs: [first.id])
        #expect(FileManager.default.fileExists(atPath: store.attachment(for: first).fileURL.path))
        let archiveURL = AppChatFileStore.fileURL(forModelDirectory: fixture.directory)
        try FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: false)
        let empty = AppChatArchive.empty()
        #expect(throws: (any Error).self) {
            try coordinator.flush(revision: 2, archive: empty, modelDirectory: fixture.directory,
                                  retiredImageIDs: [first.id])
        }
        #expect(FileManager.default.fileExists(atPath: store.attachment(for: first).fileURL.path))
        try FileManager.default.removeItem(at: archiveURL)
        try coordinator.flush(revision: 3, archive: empty, modelDirectory: fixture.directory)
        #expect(!FileManager.default.fileExists(atPath: store.attachment(for: first).fileURL.path))
        #expect(FileManager.default.fileExists(atPath: store.attachment(for: unpublished).fileURL.path))
    }
}
