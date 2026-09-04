import AppKit
import Testing
@testable import TurboFieldfareMacPresentation

@Suite @MainActor struct TranscriptHistoryImageTests {
    @Test func eachImageStaysAtItsMessageWhileAnotherAnswerStreams() {
        let controller = InstructionTranscriptDocumentController()
        let storage = NSMutableAttributedString()
        let history: [InstructionTranscriptMessage] = [
            .init(role: .user, content: "first question"),
            .init(role: .assistant, content: "first answer"),
            .init(role: .user, content: "second question"),
        ]
        let prefixes = [0: NSAttributedString(string: "[first image]"),
                        2: NSAttributedString(string: "[second image]")]
        controller.synchronize(storage: storage, history: history, response: "", isTerminal: false)
        let loaded = controller.synchronize(
            storage: storage, history: history, response: "next", isTerminal: false,
            promptPrefix: NSAttributedString(string: "[duplicate live image]"),
            promptPrefixIdentifier: "images-ready", historyImagePrefixes: prefixes)
        #expect(loaded.mutation == .rebuilt)
        #expect(storage.string.contains("[first image]\n\nfirst question"))
        #expect(storage.string.contains("[second image]\n\nsecond question"))
        #expect(!storage.string.contains("duplicate"))
        controller.synchronize(
            storage: storage, history: history, response: "next answer", isTerminal: false,
            promptPrefixIdentifier: "images-ready", historyImagePrefixes: prefixes)
        #expect(storage.string.components(separatedBy: "[first image]").count == 2)
        #expect(storage.string.components(separatedBy: "[second image]").count == 2)
        controller.synchronize(storage: storage, history: [.init(role: .user, content: "other chat")],
                               response: "", isTerminal: false)
        #expect(!storage.string.contains("image"))
    }

    @Test func unavailableImageIsVisibleAndImageOnlyMessagesRender() {
        let controller = InstructionTranscriptDocumentController()
        let storage = NSMutableAttributedString()
        controller.synchronize(
            storage: storage, history: [.init(role: .user, content: "")],
            response: "answer", isTerminal: true,
            promptPrefixIdentifier: "missing",
            historyImagePrefixes: [0: NSAttributedString(string: "[Saved image unavailable: photo.png]")])
        #expect(storage.string.contains("Saved image unavailable: photo.png"))
        #expect(storage.string.contains("answer"))
    }
}
