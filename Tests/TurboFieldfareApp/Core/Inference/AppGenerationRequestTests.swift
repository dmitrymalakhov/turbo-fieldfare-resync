import Foundation
import Testing
import TurboFieldfare
@testable import TurboFieldfareAppCore

@Suite struct AppGenerationRequestTests {
    private let existingDirectory = FileManager.default.temporaryDirectory

    @Test func defaultRequestUsesDocumentedSamplingPolicy() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory, prompt: "hello")
        #expect(request.maxNewTokens == 4_096)
        #expect(request.temperature == 0.2)
        #expect(request.topK == 64)
        #expect(request.topP == 0.95)
        #expect(request.repetitionPenalty == 1)
        #expect(!request.isPureGreedy)
    }

    @Test func temperatureZeroRemainsPureGreedyWithTruncationDefaults() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                           prompt: "hello",
                                           temperature: 0)
        #expect(request.topK == 64)
        #expect(request.topP == 0.95)
        #expect(request.isPureGreedy)
    }

    @Test func emptyPromptRejected() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory, prompt: "   ")
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func invalidMaxTokensRejected() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                           prompt: "hello", maxNewTokens: 0)
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func invalidSlotCountRejected() {
        var options = AppRuntimeOptions()
        options.expertCacheSlots = 7
        let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                           prompt: "hello", runtimeOptions: options)
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func repetitionPenaltyBelowOneRejected() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                           prompt: "hello", repetitionPenalty: 0.9)
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func invalidTopKRejected() {
        for topK in [0, 257] {
            let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                               prompt: "hello", topK: topK)
            #expect(throws: AppInferenceError.self) {
                try request.validate()
            }
        }
    }

    @Test func invalidTopPRejected() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                           prompt: "hello", topP: 1.1)
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func stochasticTopPRequiresTopK() {
        let request = AppGenerationRequest(modelDirectory: existingDirectory,
                                           prompt: "hello", topK: nil, topP: 0.95)
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func missingModelDirectoryRejected() {
        let request = AppGenerationRequest(
            modelDirectory: URL(fileURLWithPath: "/nonexistent/model.gturbo"),
            prompt: "hello")
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func imageOnlyRequestIsValid() throws {
        let attachment = StagedImage(
            fileURL: URL(fileURLWithPath: "/tmp/image.png"),
            displayName: "image.png",
            encodedBytes: 4,
            sha256: String(repeating: "a", count: 64))
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            prompt: "",
            imageAttachments: [attachment])
        try request.validate()
    }

    private func image(_ name: String) -> StagedImage {
        StagedImage(
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
            displayName: name, encodedBytes: 4,
            sha256: String(repeating: "a", count: 64))
    }

    @Test func imageCapacityShrinksAsTheConversationFills() throws {
        // An empty conversation still keeps the reply's reserve free.
        let capacity = VisionImageTokenBudget.capacity(
            maxContext: 8_192, reservedTextTokens: ConversationGenerationReserve.tokens)
        #expect(capacity >= 2, "the fixture needs room for more than one image")
        let attachments = (0..<capacity).map { image("image-\($0).png") }

        try AppGenerationRequest(
            modelDirectory: existingDirectory, prompt: "describe these",
            imageAttachments: attachments, maxContextTokens: 8_192).validate()

        let carried = 8_192 - VisionImageTokenBudget.maximumTokensPerImage
        #expect(throws: AppInferenceError.self) {
            try AppGenerationRequest(
                modelDirectory: existingDirectory, prompt: "and these",
                imageAttachments: attachments, maxContextTokens: 8_192,
                continuesConversation: true,
                conversationTokens: carried).validate()
        }
    }

    @Test func aTurnCarryingOneImageStillFitsLateInAConversation() throws {
        // One image, the reply's reserve, and a little text still fit.
        let carried = 8_192 - VisionImageTokenBudget.maximumTokensPerImage
            - ConversationGenerationReserve.tokens - 16
        try AppGenerationRequest(
            modelDirectory: existingDirectory, prompt: "what is this",
            imageAttachments: [image("one.png")], maxContextTokens: 8_192,
            continuesConversation: true,
            conversationTokens: carried).validate()
        // Without room for the reply, the same image is refused here rather
        // than after the runtime has encoded it.
        #expect(throws: AppInferenceError.self) {
            try AppGenerationRequest(
                modelDirectory: existingDirectory, prompt: "what is this",
                imageAttachments: [image("one.png")], maxContextTokens: 8_192,
                continuesConversation: true,
                conversationTokens: carried + ConversationGenerationReserve.tokens).validate()
        }
    }

    @Test func aOneShotRequestReservesNothingAndKeepsItsOldCapacity() throws {
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory, prompt: "hello")
        #expect(!request.continuesConversation)
        #expect(request.conversationTokens == 0)
        try request.validate()
    }

    @Test(arguments: [Int.min, -1, 8_193, Int.max])
    func invalidConversationTokenCountsAreRejectedBeforeBudgetArithmetic(_ tokens: Int) {
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            prompt: "hello",
            imageAttachments: [image("one.png")],
            maxContextTokens: 8_192,
            conversationTokens: tokens)

        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func conversationCannotStartWithAssistant() {
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            messages: [
                AppGenerationMessage(role: .assistant, content: "orphan answer"),
                AppGenerationMessage(role: .user, content: "question"),
            ])
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func conversationTokenBoundariesAreValid() throws {
        for tokens in [0, 8_192] {
            try AppGenerationRequest(
                modelDirectory: existingDirectory,
                prompt: "hello",
                maxContextTokens: 8_192,
                conversationTokens: tokens).validate()
        }
    }

    @Test func invalidContextCannotOverflowImageCapacity() {
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            prompt: "hello",
            imageAttachments: [image("one.png")],
            maxContextTokens: Int.min,
            conversationTokens: Int.max)

        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
        #expect(VisionImageTokenBudget.capacity(
            maxContext: Int.min, reservedTextTokens: Int.max) == 0)
        #expect(VisionImageTokenBudget.capacity(
            maxContext: Int.max, reservedTextTokens: Int.min) == 0)
    }

    @Test func everySystemMessageAfterTheFirstPositionIsRejected() {
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            messages: [
                AppGenerationMessage(role: .system, content: "first"),
                AppGenerationMessage(role: .user, content: "question"),
                AppGenerationMessage(role: .system, content: "second"),
                AppGenerationMessage(role: .user, content: "follow-up"),
            ])
        #expect(throws: AppInferenceError.self) {
            try request.validate()
        }
    }

    @Test func completeMultiTurnConversationWithLeadingSystemMessageIsValid() throws {
        let request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            messages: [
                AppGenerationMessage(role: .system, content: "memory"),
                AppGenerationMessage(role: .user, content: "question"),
                AppGenerationMessage(role: .assistant, content: "answer"),
                AppGenerationMessage(role: .user, content: "follow-up"),
            ])

        try request.validate()
        #expect(request.prompt == "follow-up")
    }

    @Test func emptyConversationEmptyMessageAndTrailingAssistantAreRejected() {
        let invalidMessageSets: [[AppGenerationMessage]] = [
            [],
            [.init(role: .user, content: "\n\t ")],
            [
                .init(role: .user, content: "question"),
                .init(role: .assistant, content: "answer"),
            ],
            [
                .init(role: .user, content: "question"),
                .init(role: .assistant, content: " "),
                .init(role: .user, content: "follow-up"),
            ],
        ]

        for messages in invalidMessageSets {
            let request = AppGenerationRequest(
                modelDirectory: existingDirectory,
                messages: messages)
            #expect(throws: AppInferenceError.self) {
                try request.validate()
            }
        }
    }

    @Test func compatibilityPromptSetterReplacesPriorConversation() {
        var request = AppGenerationRequest(
            modelDirectory: existingDirectory,
            messages: [
                .init(role: .system, content: "memory"),
                .init(role: .user, content: "old"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "follow-up"),
            ])

        request.prompt = "replacement"

        #expect(request.messages == [
            AppGenerationMessage(role: .user, content: "replacement"),
        ])
        #expect(request.prompt == "replacement")
    }

    @Test func generationMessageCodableRoundTripKeepsEveryRole() throws {
        let messages: [AppGenerationMessage] = [
            .init(role: .system, content: "memory"),
            .init(role: .user, content: "question"),
            .init(role: .assistant, content: "answer"),
        ]

        let decoded = try JSONDecoder().decode(
            [AppGenerationMessage].self,
            from: JSONEncoder().encode(messages))

        #expect(decoded == messages)
    }
    @Test func duplicateAndMalformedImageDescriptorsAreRejected() {
        let id = UUID()
        let attachment = StagedImage(
            id: id,
            fileURL: URL(fileURLWithPath: "/tmp/image.png"),
            displayName: "image.png",
            encodedBytes: 4,
            sha256: String(repeating: "a", count: 64))
        #expect(throws: AppInferenceError.self) {
            try AppGenerationRequest(
                modelDirectory: existingDirectory,
                prompt: "",
                imageAttachments: [attachment, attachment]).validate()
        }
        let malformed = StagedImage(
            fileURL: URL(fileURLWithPath: "/tmp/image.png"),
            displayName: "image.png",
            encodedBytes: 4,
            sha256: "not-a-digest")
        #expect(throws: AppInferenceError.self) {
            try AppGenerationRequest(
                modelDirectory: existingDirectory,
                prompt: "",
                imageAttachments: [malformed]).validate()
        }
    }
}
