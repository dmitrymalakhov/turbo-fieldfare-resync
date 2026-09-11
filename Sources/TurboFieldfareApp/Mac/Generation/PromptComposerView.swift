import AppKit
import TurboFieldfare
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI
import UniformTypeIdentifiers

struct PromptComposerView: View {
    @Bindable var model: AppModel
    @FocusState private var promptFocused: Bool
    @State private var showingPromptTips = false
    @State private var showingAttachmentPicker = false
    @State private var isImageDropTargeted = false
    @State private var isExtractingDocuments = false
    @State private var documentImportError: String?
    @State private var previewedAttachment: AppPromptAttachment?
    @State private var contextUsage: AppContextUsage?
    @State private var isEstimatingContext = false
    @State private var showingContextDashboard = false
    @State private var showingConversationMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = model.externalContextProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !model.composerImageAttachments.isEmpty || model.imageAttachmentError != nil {
                imageAttachmentStrip
            }
            if !model.promptAttachments.isEmpty {
                documentAttachments
            }
            if let documentImportError {
                Text(documentImportError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            editor
            footer
        }
        .fileImporter(
            isPresented: $showingAttachmentPicker,
            allowedContentTypes: attachmentPickerContentTypes,
            allowsMultipleSelection: true
        ) { handleAttachmentSelection($0) }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canEditSelectedChat, !urls.isEmpty else { return false }
            importDocuments(urls)
            return true
        }
        .sheet(item: $previewedAttachment) { attachment in
            AttachmentPreviewSheet(attachment: attachment)
        }
        .sheet(isPresented: $showingConversationMemory) {
            ConversationMemorySheet(
                memory: model.selectedChat.contextSummary ?? "")
        }
        .task(id: contextEstimationKey) {
            guard !model.promptText.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
                contextUsage = nil
                isEstimatingContext = false
                return
            }
            isEstimatingContext = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let estimatedUsage = await model.estimateSelectedContextUsage()
            guard !Task.isCancelled else { return }
            contextUsage = estimatedUsage
            isEstimatingContext = false
        }
    }

    private var editor: some View {
        PromptTextEditor(
            text: $model.promptText,
            isFocused: Binding(
                get: { promptFocused },
                set: { promptFocused = $0 }),
            newlineShortcut: model.newlineShortcut,
            canRun: model.canSubmitPrompt,
            canAcceptImages: model.isImageInputAvailable
                && !model.isTurnInFlight
                && !model.isAddingImages,
            onSubmit: model.submitPrompt,
            onImagesDropped: { model.addImages($0) },
            onImageDataPasted: model.addImageData,
            onPromisedImagesReceived: { urls, directory in
                model.addImages(urls, discardingSourceDirectory: directory)
            },
            onPromisedImagesFailed: {
                model.reportImageAttachmentError(
                    "That drag did not deliver a file TurboFieldfare could read.")
            },
            onUnsupportedImagePaste: {
                model.reportImageAttachmentError(
                    "That clipboard content is not an image TurboFieldfare can read.")
            },
            onDropTargeted: { isImageDropTargeted = $0 })
            .accessibilityLabel("Message")
            .frame(height: editorHeight)
            .overlay(alignment: .topLeading) {
                if model.promptText.isEmpty {
                    // Matches the NSTextView text origin: 5pt line fragment
                    // padding, no vertical inset.
                    Text("Message")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isImageDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.tint, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }

    private var editorHeight: CGFloat {
        let explicitLines = model.promptText.split(
            separator: "\n",
            omittingEmptySubsequences: false).count
        let wrappedLines = max(1, model.promptText.count / 84 + 1)
        let lines = min(max(max(explicitLines, wrappedLines), 3), 9)
        return CGFloat(lines * 20 + 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            attachmentAction
            promptTips
            contextControl
            Spacer()
            Text(shortcutHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            clearAction
            GenerateControl(model: model)
        }
    }

    private var imageAttachmentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                // Top-aligned so the tiles share one edge; they are all the
                // same size now, but alignment left to chance is how the row
                // drifted out of line in the first place.
                HStack(alignment: .top, spacing: 8) {
                    ForEach(model.composerImageAttachments, id: \.id) { attachment in
                        SubmittedImageThumbnail(attachment: .staged(attachment))
                            .overlay(alignment: .topTrailing) {
                            Button {
                                model.removeImage(id: attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove \(attachment.displayName)")
                            .accessibilityIdentifier(AccessibilityID.remove("\(attachment.id)"))
                        }
                        .padding(.top, 5)
                        .padding(.trailing, 5)
                    }
                }
            }
            .frame(height: 58)
            if let error = model.imageAttachmentError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var documentAttachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.promptAttachments) { attachment in
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Button {
                            previewedAttachment = attachment
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.fileName)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(attachmentDetail(attachment))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            model.removePromptAttachment(id: attachment.id)
                        } label: {
                            Label("Remove \(attachment.fileName)", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!model.canEditSelectedChat)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 7)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.35), in: .capsule)
                    .overlay {
                        Capsule().stroke(.separator.opacity(0.4), lineWidth: 0.5)
                    }
                    .help(attachment.wasTruncatedDuringExtraction
                          ? "Text was truncated during local extraction."
                          : "Text extracted locally for this prompt.")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var attachmentAction: some View {
        Button {
            documentImportError = nil
            showingAttachmentPicker = true
        } label: {
            Group {
                if isExtractingDocuments {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Attach", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!model.canEditSelectedChat || isExtractingDocuments)
        .help(attachmentActionHelp)
        .accessibilityLabel(isExtractingDocuments
                            ? "Extracting document text"
                            : "Attach files")
    }

    private var canChooseImages: Bool {
        model.isImageInputAvailable
            && !model.isRunning
            && !model.isAddingImages
            && model.composerImageAttachments.count < model.maximumImageAttachments
    }

    private var attachmentPickerContentTypes: [UTType] {
        let documents = DocumentTextExtractor.supportedContentTypes
        guard canChooseImages else { return documents }
        let images = VisionImageLimits().allowedContentTypes
        return (documents + images).reduce(into: []) { result, type in
            if !result.contains(type) { result.append(type) }
        }
    }

    private var attachmentActionHelp: String {
        if canChooseImages {
            return "Attach images, text, PDF, Word, PowerPoint, or Excel files"
        }
        return "Attach text, PDF, Word, PowerPoint, or Excel files"
    }

    private func handleAttachmentSelection(
        _ result: Result<[URL], any Error>
    ) {
        switch result {
        case .failure(let error):
            documentImportError = error.localizedDescription
        case .success(let urls):
            let imageTypes = VisionImageLimits().allowedContentTypes
            let images = urls.filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension)
                else { return false }
                return imageTypes.contains { type.conforms(to: $0) }
            }
            let imageURLs = Set(images.map(\.standardizedFileURL))
            let documents = urls.filter {
                !imageURLs.contains($0.standardizedFileURL)
            }
            if !images.isEmpty { model.addImages(images) }
            if !documents.isEmpty { importDocuments(documents) }
        }
    }

    private var promptTips: some View {
        TransientPopoverButton(
            systemImage: "questionmark.circle", help: "Prompt tips") {
            promptGuide
        }
        .frame(width: 28, height: 28)
        .accessibilityIdentifier(.composerTips)
    }

    private var promptGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prompting this model")
                .font(.headline)

            tipSection("Ask for a clear task",
                       "Say what you want the model to create, explain, plan, or transform. Put the essential context in the same prompt.")
            tipSection("Shape the answer",
                       "Specify a useful length, sections, tone, or output format. Concrete constraints work better than a long list of vague preferences.")
            tipSection("Anchor important facts",
                       "Include facts the answer must preserve and say what should be checked. Generated factual claims can still be wrong or outdated.")
            tipSection("For code and calculations",
                       "Provide types, dimensions, interfaces, edge cases, or a small scaffold. Compile or run the result before relying on it.")
            tipSection("Try a focused revision",
                       "If the answer drifts, shorten the task and make the missing requirement explicit. The default temperature is 0.20 for steadier responses.")
        }
        .font(.callout)
        .frame(width: 390, alignment: .leading)
        .padding(18)
    }

    private func tipSection(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .fontWeight(.semibold)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attachmentDetail(_ attachment: AppPromptAttachment) -> String {
        let count = attachment.approximateTokenCount.formatted(
            .number.notation(.compactName))
        let suffix = attachment.wasTruncatedDuringExtraction ? " • truncated" : ""
        return "\(attachment.formatLabel) • ≈\(count) tokens\(suffix)"
    }

    private func handleDocumentSelection(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            importDocuments(urls)
        case .failure(let error):
            documentImportError = error.localizedDescription
        }
    }

    private func importDocuments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isExtractingDocuments = true
        documentImportError = nil

        Task {
            let outcomes = await Task.detached(priority: .userInitiated) {
                urls.map { url -> DocumentImportOutcome in
                    do {
                        return .success(try DocumentTextExtractor.extract(from: url))
                    } catch {
                        return .failure(fileName: url.lastPathComponent,
                                        message: error.localizedDescription)
                    }
                }
            }.value

            var failures: [String] = []
            for outcome in outcomes {
                switch outcome {
                case .success(let document):
                    model.addPromptAttachment(AppPromptAttachment(
                        fileName: document.fileName,
                        formatLabel: document.formatLabel,
                        extractedText: document.text,
                        wasTruncatedDuringExtraction: document.wasTruncated))
                case .failure(let fileName, let message):
                    failures.append("\(fileName): \(message)")
                }
            }
            documentImportError = failures.isEmpty
                ? nil
                : failures.joined(separator: "\n")
            isExtractingDocuments = false
        }
    }

    @ViewBuilder
    private var clearAction: some View {
        if !model.isRunning
            && (!model.promptText.isEmpty || !model.composerImageAttachments.isEmpty
                || !model.promptAttachments.isEmpty) {
            Button {
                model.promptText = ""
                model.clearImages()
                model.clearPromptAttachments()
                promptFocused = true
            } label: {
                Label("Clear input", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help("Clear text and attachments")
        } else if !model.isRunning && model.hasOutputTranscript {
            Button {
                model.clearOutput()
            } label: {
                Label("Clear chat history", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help("Clear chat history")
        }
        // No trash-icon "new chat" here any more. The window control beside the
        // traffic lights and Cmd+N own that action, and once chats are kept a
        // trash glyph reads as delete — which, next to a list where delete is a
        // real and different thing, is the wrong promise to make.
    }

    private var contextControl: some View {
        Button {
            showingContextDashboard.toggle()
        } label: {
            HStack(spacing: 6) {
                if let contextUsage {
                    ProgressView(value: contextUsage.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 48)
                        .tint(contextTint(contextUsage))
                    Text(
                        "\(compactTokens(contextUsage.promptTokens)) / "
                            + compactTokens(contextUsage.maximumTokens))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(contextTint(contextUsage))
                } else {
                    Image(systemName: "brain")
                    Text("Context")
                        .font(.caption)
                }
                if isEstimatingContext {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.25), in: .capsule)
        .help(contextHelp)
        .accessibilityLabel("Context usage")
        .accessibilityValue(contextAccessibilityValue)
        .popover(
            isPresented: $showingContextDashboard,
            attachmentAnchor: .point(.top),
            arrowEdge: .top
        ) {
            ContextDashboardView(
                model: model,
                usage: contextUsage,
                isEstimating: isEstimatingContext,
                showMemory: showConversationMemory,
                branchChat: branchSelectedChat,
                startCleanChat: startCleanChat)
        }
    }

    private func contextTint(_ usage: AppContextUsage) -> Color {
        if usage.isOverflowing { return .red }
        if usage.requiresHistoryCompression || usage.fraction >= 0.85 {
            return .orange
        }
        return .secondary
    }

    private var contextHelp: String {
        guard let contextUsage else {
            return "Inspect conversation memory and context for the next message"
        }
        if contextUsage.isOverflowing {
            return "The current request does not fit the selected context window."
        }
        if contextUsage.requiresHistoryCompression {
            return "Older messages will be compressed to fit the next request."
        }
        return "Prompt context: \(contextUsage.promptTokens) tokens. "
            + "About \(contextUsage.remainingTokens) tokens remain for the response."
    }

    private var contextAccessibilityValue: String {
        guard let contextUsage else { return "Exact usage not estimated" }
        return "\(contextUsage.promptTokens) of \(contextUsage.maximumTokens) tokens"
    }

    private func showConversationMemory() {
        showingContextDashboard = false
        Task { @MainActor in
            await Task.yield()
            showingConversationMemory = true
        }
    }

    private func branchSelectedChat() {
        showingContextDashboard = false
        model.branchChat(from: model.selectedChatID)
    }

    private func startCleanChat() {
        showingContextDashboard = false
        model.createChat()
    }

    private func compactTokens(_ value: Int) -> String {
        value >= 1_024
            ? String(format: "%.1fK", Double(value) / 1_024)
            : "\(value)"
    }

    private var shortcutHint: String {
        switch model.newlineShortcut {
        case .return: "⌘↩ to send"
        case .shiftReturn: "↩ to send"
        }
    }

    private var contextEstimationKey: Int {
        var hasher = Hasher()
        hasher.combine(model.selectedChatID)
        hasher.combine(model.maxContextTokens)
        hasher.combine(model.promptText)
        hasher.combine(model.selectedChat.contextSummary)
        hasher.combine(model.selectedChat.summarizedThroughMessageID)
        for message in model.selectedChat.messages {
            hasher.combine(message.id)
            hasher.combine(message.content)
            hasher.combine(message.contextContent)
        }
        for attachment in model.promptAttachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.characterCount)
        }
        return hasher.finalize()
    }
}

private struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Binding<Bool>
    let newlineShortcut: AppNewlineShortcut
    let canRun: Bool
    let canAcceptImages: Bool
    let onSubmit: () -> Void
    let onImagesDropped: ([URL]) -> Void
    let onImageDataPasted: (Data, String) -> Void
    let onPromisedImagesReceived: ([URL], URL) -> Void
    let onPromisedImagesFailed: () -> Void
    let onUnsupportedImagePaste: () -> Void
    let onDropTargeted: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ImageDropTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityIdentifier(AccessibilityID.composerMessage.rawValue)
        // A promise-only drag — Photos, Mail, most browsers — never reaches
        // `draggingEntered` unless its types are registered here.
        textView.registerForDraggedTypes(
            textView.registeredDraggedTypes
                + NSFilePromiseReceiver.readableDraggedTypes.map {
                    NSPasteboard.PasteboardType(rawValue: $0)
                })

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ImageDropTextView else { return }
        context.coordinator.parent = self
        textView.canAcceptImages = canAcceptImages
        textView.onImagesDropped = onImagesDropped
        textView.onImageDataPasted = onImageDataPasted
        textView.onPromisedImagesReceived = onPromisedImagesReceived
        textView.onPromisedImagesFailed = onPromisedImagesFailed
        textView.onUnsupportedImagePaste = onUnsupportedImagePaste
        textView.onDropTargeted = onDropTargeted
        if textView.string != text {
            textView.string = text
        }
        if isFocused.wrappedValue,
           textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor
        weak var textView: NSTextView?

        init(_ parent: PromptTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
                return false
            }
            let event = NSApp.currentEvent
            switch PromptSubmissionPolicy.decision(
                newlineShortcut: parent.newlineShortcut,
                modifiers: Self.modifiers(event?.modifierFlags ?? []),
                canRun: parent.canRun,
                hasMarkedText: textView.hasMarkedText(),
                isRepeat: event?.isARepeat == true) {
            case .submit:
                parent.onSubmit()
                return true
            case .consume:
                return true
            case .deferToEditor:
                return false
            }
        }

        private static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
            var modifiers: EventModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            return modifiers
        }
    }
}

private final class ImageDropTextView: NSTextView {
    var canAcceptImages = false
    var onImagesDropped: (([URL]) -> Void)?
    /// Promised files arrive in a directory we made and must not keep.
    var onPromisedImagesReceived: (([URL], URL) -> Void)?
    var onImageDataPasted: ((Data, String) -> Void)?
    var onUnsupportedImagePaste: (() -> Void)?
    var onPromisedImagesFailed: (() -> Void)?
    var onDropTargeted: ((Bool) -> Void)?

    override func paste(_ sender: Any?) {
        guard canAcceptImages else {
            super.paste(sender)
            return
        }
        let pasteboard = NSPasteboard.general
        switch ImagePasteboardPayload.read(from: pasteboard) {
        case .fileURLs(let urls):
            onImagesDropped?(urls)
        case .image(let data, let name):
            onImageDataPasted?(data, name)
        case .unsupportedImage:
            onUnsupportedImagePaste?()
        case .text, .none:
            super.paste(sender)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesImages(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        guard canAcceptImages else { return [] }
        onDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard carriesImages(sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        return canAcceptImages ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted?(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        if !urls.isEmpty {
            onDropTargeted?(false)
            guard canAcceptImages else { return false }
            onImagesDropped?(urls)
            return true
        }
        let promises = filePromises(from: sender.draggingPasteboard)
        guard !promises.isEmpty else { return super.performDragOperation(sender) }
        onDropTargeted?(false)
        guard canAcceptImages else { return false }
        receive(promises)
        return true
    }

    /// Drags from Photos, Mail and most browsers carry a promise rather than a
    /// file: the source writes the bytes only once a destination asks for them.
    /// Without this the drop was simply refused.
    private func receive(_ promises: [NSFilePromiseReceiver]) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboFieldfare-Promises", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
        } catch {
            // Failing to make a staging directory is a disk or permission
            // failure, not a statement about what was dropped. Reporting it as
            // unsupported content sent someone off converting file formats
            // because the volume was full.
            onPromisedImagesFailed?()
            return
        }
        let queue = OperationQueue()
        // One completion arrives per promised FILE, not per receiver: a legacy
        // promiser puts several file names on a single pasteboard item. Counting
        // receivers finished the batch at the first file and handed the
        // directory straight to `addImages`, whose `defer` deleted it while
        // AppKit was still writing the rest — so a three-image drag attached one
        // and destroyed two, with nothing reporting the loss.
        let expected = promises.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let received = ReceivedPromises(expected: expected)
        for promise in promises {
            promise.receivePromisedFiles(
                atDestination: destination,
                options: [:],
                operationQueue: queue
            ) { [weak self] url, error in
                // The staged copy is what the request uses, so the promised
                // file is only needed until then.
                let finished = received.record(url: error == nil ? url : nil)
                guard let finished else { return }
                DispatchQueue.main.async {
                    if finished.isEmpty {
                        // A promise that failed is not "unsupported content";
                        // saying so sends the user looking for the wrong thing.
                        self?.onPromisedImagesFailed?()
                        try? FileManager.default.removeItem(at: destination)
                    } else if let handler = self?.onPromisedImagesReceived {
                        handler(finished, destination)
                    } else {
                        // The text view went away before the promises resolved,
                        // so nothing downstream will ever own this directory:
                        // the optional chain was a no-op and the sweep covers
                        // only the staging root, so a closed window left the
                        // full-size copies behind for every future launch.
                        try? FileManager.default.removeItem(at: destination)
                    }
                }
            }
        }
    }

    /// Only files in a format the vision pack can actually decode. Without the
    /// conformance filter any file URL was staged: copying a document in Finder
    /// and pressing Cmd-V attached it, replacing the editor's own paste, and the
    /// failure surfaced only once the run reached image decoding.
    ///
    /// The list is the runtime's, not `public.image`: conforming to
    /// `public.image` admits camera RAW, EXR and WebP, which are copied at full
    /// size and decoded for a thumbnail before the run refuses them. The picker
    /// reads the same list, and paste, drop and the drag-accept highlight all
    /// read through here, so the four stay in agreement.
    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes:
                    Array(VisionImageLimits().allowedTypeIdentifiers),
            ]) as? [NSURL]
        return objects?.map { $0 as URL } ?? []
    }

    private func filePromises(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    private func carriesImages(_ pasteboard: NSPasteboard) -> Bool {
        !fileURLs(from: pasteboard).isEmpty || !filePromises(from: pasteboard).isEmpty
    }

}

/// Collects the results of a multi-file promise drop, which arrive one
/// completion at a time on an arbitrary queue.
private final class ReceivedPromises: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var urls: [URL] = []
    private var completed = 0

    init(expected: Int) {
        self.expected = expected
    }

    /// Returns the collected URLs once every promise has reported, and nil
    /// until then.
    func record(url: URL?) -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        if let url { urls.append(url) }
        completed += 1
        return completed == expected ? urls : nil
    }
}

private enum DocumentImportOutcome: Sendable {
    case success(ExtractedPromptDocument)
    case failure(fileName: String, message: String)
}

private struct AttachmentPreviewSheet: View {
    let attachment: AppPromptAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.fileName)
                        .font(.title3.weight(.semibold))
                    Text("Extracted locally · approximately \(attachment.approximateTokenCount.formatted()) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if attachment.wasTruncatedDuringExtraction {
                Label("The extracted text was truncated.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                Text(previewText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
    }

    private var previewText: String {
        let maximumPreviewCharacters = 50_000
        let prefix = String(attachment.extractedText.prefix(maximumPreviewCharacters))
        if prefix.count < attachment.extractedText.count {
            return prefix + "\n\n[Preview shortened; the full extracted text remains attached.]"
        }
        return prefix
    }
}
