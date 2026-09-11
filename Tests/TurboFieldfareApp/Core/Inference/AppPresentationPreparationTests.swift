import Foundation
import Testing
@testable import TurboFieldfareAppCore

@Suite struct AppPresentationPreparationTests {
    @Test func promptRequestsAnAudienceFacingSlideDraftWithoutInventedFacts() {
        let prompt = AppPresentationPreparation.prompt

        #expect(prompt.contains("same language"))
        #expect(prompt.contains("8 to 12 slides"))
        #expect(prompt.contains("Do not invent"))
        #expect(prompt.contains("# Slide N - Audience-facing title"))
        #expect(prompt.contains("Speaker notes:"))
    }

    @Test func presentationTitleIsTrimmedToChatTitleLimit() {
        let title = AppPresentationPreparation.title(
            from: String(repeating: "x", count: 100))

        #expect(title.count == 80)
        #expect(title.hasSuffix(" - presentation"))
    }

    @MainActor
    @Test func preparationBranchesTheAnswerAndRunsTheSameInferenceClient() async throws {
        let client = MockInferenceClient(response: "source answer", tokenDelayNanos: 1)
        client.prefillSteps = 0
        let model = AppModel(client: client)
        let directory = FileManager.default.temporaryDirectory
        model.modelPathText = directory.path
        model.loadState = .ready(modelDirectory: directory, loadSeconds: 0)
        model.maxNewTokensOverride = 2
        model.promptText = "Create a source answer"
        model.run()
        await waitForIdle(model)

        let sourceChatID = model.selectedChatID
        model.promptText = "Keep this unsent draft"
        #expect(model.canPreparePresentationFromResponse)

        let branchID = try #require(model.preparePresentationFromResponse())
        await SendWaiting.generationStarts(model)
        let source = try #require(model.chats.first { $0.id == sourceChatID })
        let branch = try #require(model.chats.first { $0.id == branchID })

        #expect(branchID != sourceChatID)
        #expect(model.selectedChatID == branchID)
        #expect(source.draft == "Keep this unsent draft")
        #expect(branch.title.hasSuffix(" - presentation"))
        let presentationRequest = try #require(branch.messages.first {
            $0.role == .user && $0.content == AppPresentationPreparation.prompt
        })
        let requestIndex = try #require(branch.messages.firstIndex {
            $0.id == presentationRequest.id
        })
        #expect(requestIndex > branch.messages.startIndex)
        #expect(branch.messages[branch.messages.index(before: requestIndex)].role
            == .assistant)

        await waitForIdle(model)
        #expect(model.selectedChat.messages.last?.role == .assistant)
        let exportRequest = try #require(model.presentationExportRequest)
        #expect(exportRequest.chatID == branchID)
        #expect(exportRequest.markdown == model.selectedChat.messages.last?.content)

        model.consumePresentationExportRequest(id: exportRequest.id)
        #expect(model.presentationExportRequest == nil)
    }

    @MainActor
    @Test func preparationIsUnavailableWithoutAnAssistantAnswer() {
        let model = AppModel()
        let directory = FileManager.default.temporaryDirectory
        model.loadState = .ready(modelDirectory: directory, loadSeconds: 0)

        #expect(!model.canPreparePresentationFromResponse)
        #expect(model.preparePresentationFromResponse() == nil)
    }

    @MainActor
    private func waitForIdle(_ model: AppModel) async {
        await SendWaiting.turnEnds(model)
    }
}
