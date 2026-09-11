import Foundation
import Testing
import TurboFieldfare
@testable import TurboFieldfareAppCore

@Suite struct UpstreamHistoryIntegrationTests {
    @MainActor @Test func failedTurnReturnsToItsOwnChatAfterNavigation() {
        let model = AppModel(client: MockInferenceClient())
        let sourceID = model.selectedChatID
        let attachment = image()
        let turn = PreparedTurn(prompt: "original question", images: [attachment], chatID: sourceID)
        let otherID = model.createChat()
        model.promptText = "other draft"
        model.restoreComposer(turn, error: nil, withdrawingFromTranscript: true)
        #expect(model.selectedChatID == otherID)
        #expect(model.promptText == "other draft")
        #expect(model.imageAttachments.isEmpty)
        model.selectChat(id: sourceID)
        #expect(model.promptText == "original question")
        #expect(model.imageAttachments == [attachment])
    }

    private func image(_ id: UUID = UUID()) -> StagedImage {
        StagedImage(id: id, fileURL: URL(fileURLWithPath: "/tmp/imported-image.png"),
                    displayName: "image.png", encodedBytes: 4,
                    sha256: String(repeating: "a", count: 64))
    }

    @Test func importedHistoryKeepsRolesAndImagePositions() throws {
        let first = image()
        let second = image()
        let request = AppGenerationRequest(
            modelDirectory: FileManager.default.temporaryDirectory,
            messages: [
                .init(role: .system, content: "Earlier memory"),
                .init(role: .user, content: "", imageIDs: [first.id]),
                .init(role: .assistant, content: "Earlier answer"),
                .init(role: .user, content: "Compare these", imageIDs: [second.id]),
            ], imageAttachments: [first, second], maxContextTokens: 8_192)
        try request.validate(requireModelDirectory: false)
        let opening = try #require(RealInferenceSession.openingMessages(for: request))
        #expect(opening.map(\.role) == [.system, .user, .assistant, .user])
        #expect(opening[1].content == [.image(id: first.id)])
        #expect(opening[3].content == [.image(id: second.id), .text("Compare these")])
        #expect(opening[2].content == [.text("Earlier answer")])
    }

    @Test func messageImageAssignmentsFailClosed() {
        let attachment = image()
        let invalid: [[AppGenerationMessage]] = [
            [.init(role: .user, content: "Unknown", imageIDs: [UUID()])],
            [.init(role: .user, content: "Duplicate", imageIDs: [attachment.id, attachment.id])],
            [.init(role: .system, content: "Wrong role", imageIDs: [attachment.id]),
             .init(role: .user, content: "Question", imageIDs: [])],
            [.init(role: .user, content: "Missing reference", imageIDs: [])],
        ]
        for messages in invalid {
            #expect(throws: AppInferenceError.self) {
                try AppGenerationRequest(modelDirectory: FileManager.default.temporaryDirectory,
                    messages: messages, imageAttachments: [attachment])
                    .validate(requireModelDirectory: false)
            }
        }
    }

    @Test func legacyMessageJSONStillDecodesAndMappedMessagesRoundTrip() throws {
        let legacy = Data(#"{"role":"user","content":"hello"}"#.utf8)
        #expect(try JSONDecoder().decode(AppGenerationMessage.self, from: legacy).imageIDs == nil)
        let mapped = AppGenerationMessage(role: .user, content: "look", imageIDs: [UUID()])
        #expect(try JSONDecoder().decode(AppGenerationMessage.self,
            from: JSONEncoder().encode(mapped)) == mapped)
    }

    @Test func preparedTurnCarriesDocumentContextWhenItsFilesChange() {
        let chatID = UUID()
        let document = AppPromptAttachment(fileName: "notes.txt", formatLabel: "Text",
                                            extractedText: "document contents")
        let original = PreparedTurn(prompt: "question", images: [], chatID: chatID,
                                    documents: [document], contextContent: "edited context")
        let retained = image()
        let carried = original.carrying([retained])
        #expect(carried.chatID == chatID)
        #expect(carried.documents == [document])
        #expect(carried.contextContent == "edited context")
        #expect(carried.images == [retained])
    }
}
