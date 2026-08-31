import AppKit
import TurboFieldfare
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI
import UniformTypeIdentifiers

struct OutputPaneView: View {
    let model: AppModel
    @State private var responseCopyFeedbackID: UUID?
    @State private var messageBeingEdited: AppChatMessage?
    @State private var showingClearConfirmation = false
    @State private var showingConversationMemory = false

    var body: some View {
        Group {
            if model.hasOutputTranscript {
                transcript
            } else if model.selectedChat.branchedFromChatID != nil {
                branchedPlaceholder
            } else {
                placeholder
            }
        }
        .task(id: responseCopyFeedbackID) {
            guard let feedbackID = responseCopyFeedbackID else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, responseCopyFeedbackID == feedbackID else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                responseCopyFeedbackID = nil
            }
        }
        .sheet(item: $messageBeingEdited) { message in
            EditChatMessageSheet(message: message) { replacement in
                model.branchChat(
                    from: model.selectedChatID,
                    editingMessage: message.id,
                    replacementContent: replacement)
            }
        }
        .sheet(isPresented: $showingConversationMemory) {
            ConversationMemorySheet(
                memory: model.selectedChat.contextSummary ?? "")
        }
        .confirmationDialog(
            "Clear this chat's history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                model.clearOutput()
            }
            Button("Keep History", role: .cancel) {}
        } message: {
            Text("Messages and compressed memory will be removed. You can undo this immediately afterward.")
        }
        .contextMenu {
            if !model.selectedChat.messages.isEmpty {
                Button("Branch chat") {
                    model.branchChat(from: model.selectedChatID)
                }
                .disabled(!model.canEditSelectedChat)

                branchFromMessageMenu
                editMessageMenu

                Divider()
            }

            Button("Copy response") {
                copyResponse()
            }
            .disabled(model.outputResponsePlainText.isEmpty)

            Button("Copy prompt") {
                copy(model.displayedOutputPromptText)
            }
            .disabled(model.displayedOutputPromptText.isEmpty)

            Button("Copy conversation") {
                copy(model.outputConversationPlainText)
            }
            .disabled(model.outputConversationPlainText.isEmpty)

            Divider()

            Button("Export Conversation…", action: exportConversation)
                .disabled(model.outputConversationPlainText.isEmpty)

            Button("Clear chat history") { showingClearConfirmation = true }
                .disabled(!model.canEditSelectedChat || !model.hasOutputTranscript)
        }
    }

    private var placeholder: some View {
        EmptyConversationLayout(spacing: 8) {
            EmptyPlaceholderIcon(systemName: placeholderSymbol)
                .frame(width: 32, height: 32)

            emptyPlaceholderContent
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var branchedPlaceholder: some View {
        VStack(spacing: 0) {
            branchSourceBanner
                .padding(.horizontal, 24)
                .padding(.top, 20)
            placeholder
        }
    }

    private var transcript: some View {
        VStack(spacing: 10) {
            if model.selectedChat.branchedFromChatID != nil {
                branchSourceBanner
            }
            if model.isSelectedChatRunning {
                IncrementalTranscriptView(
                    messages: model.transcriptBaseMessages.map { message in
                        InstructionTranscriptMessage(
                            role: message.role == .user ? .user : .assistant,
                            content: message.content,
                            isEdited: isEditedAssistantMessage(message))
                    },
                    lastAnswer: model.outputResponsePlainText,
                    conversationPlainText: model.outputConversationPlainText,
                    requestNewChat: model.isRunning ? nil : { model.newChat() },
                    prompt: model.outputPromptText,
                    images: model.outputImageAttachments,
                    output: model.outputText,
                    mailbox: model.generationTranscriptMailbox,
                    isTerminal: false,
                    showsPrefillPlaceholder: model.outputResponsePlainText.isEmpty,
                    runIdentity: model.runIdentity,
                    isOutputEdited: false)
                    .id(model.selectedChatID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConversationTranscriptView(
                    messages: model.transcriptBaseMessages,
                    response: model.outputResponsePlainText,
                    responseMessage: model.displayedResponseMessage,
                    summaryBoundaryID: model.selectedChat.summarizedThroughMessageID,
                    canEdit: model.canEditSelectedChat,
                    isEdited: isEditedAssistantMessage,
                    copy: copy,
                    edit: { messageBeingEdited = $0 },
                    branch: { message in
                        model.branchChat(
                            from: model.selectedChatID,
                            throughMessage: message.id)
                    },
                    regenerate: { message in
                        model.regenerateAssistantMessage(
                            in: model.selectedChatID,
                            messageID: message.id)
                    },
                    showMemory: { showingConversationMemory = true })
                    .id(model.selectedChatID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var branchSourceBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(TurboFieldfareMacTheme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let source = model.branchSourceChat(
                    for: model.selectedChatID) {
                    Text(branchSourceTitle(source: source))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let point = model.branchSourceMessage(
                        for: model.selectedChatID) {
                        Text(branchPointText(point))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Source chat is no longer available")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.branchSourceChat(for: model.selectedChatID) != nil {
                Button("Go to source") {
                    model.selectBranchSource(of: model.selectedChatID)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canNavigateChats)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.4), lineWidth: 0.5)
        }
    }

    private var transcriptActions: some View {
        HStack(spacing: 6) {
            editMessageButton
            branchChatButton
            if !model.outputResponsePlainText.isEmpty {
                copyResponseButton
            }
        }
    }

    private var editMessageButton: some View {
        Menu {
            editMessageButtons
        } label: {
            Image(systemName: "pencil")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit a message and branch from it")
        .accessibilityLabel("Edit message")
    }

    private var branchChatButton: some View {
        Menu {
            Button("Branch entire chat") {
                model.branchChat(from: model.selectedChatID)
            }
            Divider()
            branchFromMessageButtons
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Branch this chat or continue from a specific message")
        .accessibilityLabel("Branch chat")
    }

    private var branchFromMessageMenu: some View {
        Menu("Branch from message") {
            branchFromMessageButtons
        }
        .disabled(!model.canEditSelectedChat)
    }

    @ViewBuilder
    private var branchFromMessageButtons: some View {
        ForEach(Array(model.selectedChat.messages.enumerated()), id: \.element.id) {
            index, message in
            Button {
                model.branchChat(
                    from: model.selectedChatID,
                    throughMessage: message.id)
            } label: {
                Text(messageMenuLabel(message, index: index))
            }
        }
    }

    private var editMessageMenu: some View {
        Menu("Edit message") {
            editMessageButtons
        }
        .disabled(!model.canEditSelectedChat)
    }

    @ViewBuilder
    private var editMessageButtons: some View {
        ForEach(Array(model.selectedChat.messages.enumerated()), id: \.element.id) {
            index, message in
            Button {
                messageBeingEdited = message
            } label: {
                Text(messageMenuLabel(message, index: index))
            }
        }
    }

    private func messageMenuLabel(
        _ message: AppChatMessage,
        index: Int
    ) -> String {
        let role = message.role == .user ? "You" : "Answer"
        let oneLine = message.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = oneLine.isEmpty ? "Empty message" : String(oneLine.prefix(48))
        return "\(index + 1). \(role): \(preview)"
    }

    private func branchSourceTitle(source: AppChat) -> String {
        switch model.selectedChat.branchKind {
        case .editedUserMessage:
            return "Edited from \(source.title)"
        case .editedAssistantMessage:
            return "Edited answer from \(source.title)"
        case .chatCopy, .messageContinuation, .none:
            return "Branched from \(source.title)"
        }
    }

    private func branchPointText(_ message: AppChatMessage) -> String {
        let role = message.role == .user ? "You" : "Answer"
        let oneLine = message.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(role): \(String(oneLine.prefix(100)))"
    }

    private func isEditedAssistantMessage(_ message: AppChatMessage) -> Bool {
        model.selectedChat.editedAssistantMessageIDs?.contains(message.id) == true
    }

    private var isDisplayedOutputEdited: Bool {
        guard !model.isRunning,
              let lastMessage = model.selectedChat.messages.last,
              lastMessage.role == .assistant else {
            return false
        }
        return isEditedAssistantMessage(lastMessage)
    }

    private var copyResponseButton: some View {
        Button {
            copyResponse()
        } label: {
            Image(systemName: responseCopyFeedbackID == nil
                  ? "doc.on.doc"
                  : "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(responseCopyFeedbackID == nil
                                 ? Color.secondary
                                 : TurboFieldfareMacTheme.accentColor)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(responseCopyFeedbackID == nil
                            ? "Copy last answer"
                            : "Response copied")
        .accessibilityHint("Copies only the generated answer")
        .help(responseCopyFeedbackID == nil
              ? "Copy last answer"
              : "Response copied")
    }

    private var emptyPlaceholderContent: some View {
        VStack(spacing: 8) {
            if !needsModelLoad {
                Text("Start a chat, or choose a predefined example.")
                    .font(.headline)
                Text("Each message keeps the ones before it in context.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isLoadingModel {
                LoadingModelText()
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if let placeholderHint {
                Text(placeholderHint)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            if let detail = model.presentation.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(model.presentation.severity == .error ? .red : .secondary)
                    .multilineTextAlignment(.center)
            }
            if model.canLoadModel {
                Button(model.loadState.isFailed ? "Retry Load" : "Load Model",
                       action: model.loadModel)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if isLoadingModel {
                Button("Load Model", action: {})
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .hidden()
                    .accessibilityHidden(true)
            } else if model.canReloadModel {
                Button("Reload Model", action: model.reloadModel)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var needsModelLoad: Bool {
        !model.loadState.isReady
    }

    private var isLoadingModel: Bool {
        if case .loading = model.loadState { return true }
        return false
    }

    private var placeholderSymbol: String {
        "cube.transparent"
    }

    private var placeholderHint: String? {
        if model.loadState.isFailed { return "The model could not be loaded" }
        if model.hasStaleLoadedRuntime { return "Reload the model to use changed settings" }
        return needsModelLoad ? "Load the model to begin" : nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyResponse() {
        copy(model.outputResponsePlainText)
        withAnimation(.easeIn(duration: 0.15)) {
            responseCopyFeedbackID = UUID()
        }
    }

    private func exportConversation() {
        let panel = NSSavePanel()
        panel.title = "Export Conversation"
        panel.nameFieldStringValue = model.selectedChat.title + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = model.outputConversationPlainText
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            model.error = .unknown("Conversation could not be exported: \(error)")
        }
    }
}

private struct EditChatMessageSheet: View {
    let message: AppChatMessage
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var replacement: String

    init(
        message: AppChatMessage,
        onCommit: @escaping (String) -> Void
    ) {
        self.message = message
        self.onCommit = onCommit
        _replacement = State(initialValue: message.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(message.role == .user ? "Edit your message" : "Edit answer")
                .font(.title3.weight(.semibold))
            Text("A new branch will keep the context before this message. Later turns will remain in the original chat.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if message.role == .user,
               message.contextContent != message.content {
                Label(
                    "The attached document context will be kept unless you change the draft again before sending.",
                    systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $replacement)
                .font(.body)
                .frame(minHeight: 150)
                .padding(6)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.6), lineWidth: 0.5)
                }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Create branch") {
                    onCommit(replacement)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(replacement.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct ConversationTranscriptView: View {
    let messages: [AppChatMessage]
    let response: String
    let responseMessage: AppChatMessage?
    let summaryBoundaryID: AppChatMessage.ID?
    let canEdit: Bool
    let isEdited: (AppChatMessage) -> Bool
    let copy: (String) -> Void
    let edit: (AppChatMessage) -> Void
    let branch: (AppChatMessage) -> Void
    let regenerate: (AppChatMessage) -> Void
    let showMemory: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(messages) { message in
                    TranscriptMessageRow(
                        message: message,
                        content: message.content,
                        canEdit: canEdit,
                        isEdited: isEdited(message),
                        copy: copy,
                        edit: edit,
                        branch: branch,
                        regenerate: regenerate)
                    if summaryBoundaryID == message.id {
                        ContextMemoryNotice(showMemory: showMemory)
                    }
                }
                if !response.isEmpty {
                    if let responseMessage {
                        TranscriptMessageRow(
                            message: responseMessage,
                            content: response,
                            canEdit: canEdit,
                            isEdited: isEdited(responseMessage),
                            copy: copy,
                            edit: edit,
                            branch: branch,
                            regenerate: regenerate)
                        if summaryBoundaryID == responseMessage.id {
                            ContextMemoryNotice(showMemory: showMemory)
                        }
                    } else {
                        TranscriptResponseRow(content: response)
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        }
        .textSelection(.enabled)
    }
}

private struct TranscriptMessageRow: View {
    let message: AppChatMessage
    let content: String
    let canEdit: Bool
    let isEdited: Bool
    let copy: (String) -> Void
    let edit: (AppChatMessage) -> Void
    let branch: (AppChatMessage) -> Void
    let regenerate: (AppChatMessage) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.role == .user
                                     ? Color.secondary
                                     : Color.accentColor)
                if isEdited {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.4), in: .capsule)
                }
                Spacer()
                messageActions
                    .opacity(isHovered ? 1 : 0.18)
            }
            messageContent
        }
        .padding(message.role == .user ? 14 : 4)
        .background(
            message.role == .user
                ? Color(nsColor: .controlBackgroundColor)
                : Color.clear,
            in: .rect(cornerRadius: 14))
        .overlay {
            if message.role == .user {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.35), lineWidth: 0.5)
            }
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role == .assistant,
           let attributed = try? AttributedString(
               ResponseMarkdownRenderer().render(content).attributedString,
               including: \.appKit) {
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageActions: some View {
        HStack(spacing: 2) {
            Button {
                copy(content)
            } label: {
                Label("Copy message", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .help("Copy message")
            if canEdit {
                Button {
                    edit(message)
                } label: {
                    Label("Edit and branch", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .help("Edit this message and create a branch")
                Button {
                    branch(message)
                } label: {
                    Label("Continue from here", systemImage: "arrow.triangle.branch")
                        .labelStyle(.iconOnly)
                }
                .help("Continue from this message in a new branch")
                if message.role == .assistant {
                    Button {
                        regenerate(message)
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help("Regenerate this answer in a new branch")
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }

    private var roleLabel: String {
        message.role == .user ? "You" : "Answer"
    }
}

private struct TranscriptResponseRow: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Answer")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContextMemoryNotice: View {
    let showMemory: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
            Text("Earlier messages are represented by compressed memory")
            Spacer()
            Button("View Memory", action: showMemory)
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 9))
    }
}

struct ConversationMemorySheet: View {
    let memory: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Compressed Conversation Memory")
                        .font(.title3.weight(.semibold))
                    Text("This is what the model receives instead of older full turns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(memory, forType: .string)
                }
                .disabled(memory.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(memory)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 10))
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }
}

struct SubmittedImageThumbnail: View {
    let attachment: AppImageAttachment
    let maximumSize: CGSize
    @State private var image: NSImage?

    init(
        attachment: AppImageAttachment,
        maximumSize: CGSize = CGSize(width: 48, height: 48)
    ) {
        self.attachment = attachment
        self.maximumSize = maximumSize
    }

    var body: some View {
        Group {
            if let image {
                // Filled and cropped to a tile, not fitted inside one. Fitting
                // gave every attachment a different height — a screenshot came
                // out a third the height of a portrait photo — so a row of them
                // was ragged, and the remove badge, pinned to the tile, floated
                // clear of the short ones.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: maximumSize.width, height: maximumSize.height)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(width: maximumSize.width, height: maximumSize.height)
            }
        }
        .frame(width: maximumSize.width, height: maximumSize.height)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .accessibilityLabel("Attached image \(attachment.displayName)")
        .task(id: "\(attachment.id)-\(maximumSize.width)x\(maximumSize.height)") {
            let url = attachment.fileURL
            let key = attachment.sha256
            let pixels = Int(ceil(max(maximumSize.width, maximumSize.height) * 2))
            // This closure runs on the main actor, and a source near the decode
            // budget takes long enough that decoding here stalled the window.
            // The decode is done off the main thread and left in the cache; the
            // read below is then a lookup.
            await Task.detached(priority: .userInitiated) {
                _ = Self.loadThumbnail(
                    at: url, maximumPixelSize: pixels, cacheKey: key)
            }.value
            image = Self.loadThumbnail(
                at: url, maximumPixelSize: pixels, cacheKey: key)
        }
    }

    /// The transcript lays images out inline, where cropping would hide part of
    /// what was sent, so that path fits rather than fills.
    static func fittedSize(_ source: CGSize, within maximumSize: CGSize) -> CGSize {
        TranscriptImageTile.fittedSize(source, within: maximumSize)
    }

    /// Every attached-image decode in the app goes through here, so the decode
    /// budget cannot be applied to one caller and forgotten on the next. Nil
    /// means refused or unreadable; both callers draw their placeholder for it.
    nonisolated static func loadThumbnail(
        at url: URL,
        maximumPixelSize: Int,
        cacheKey: String? = nil
    ) -> NSImage? {
        TranscriptImageLoader.thumbnail(
            at: url,
            maximumPixelSize: maximumPixelSize,
            budget: decodeBudget,
            cacheKey: cacheKey)
    }

    /// The single point where the app binds the runtime's limits, so the two
    /// cannot drift apart: see `VisionImageLimits` in
    /// Runtime/Vision/Preprocessing/ImageMetadataReader.swift.
    nonisolated private static let decodeBudget: TranscriptImageLoader.Budget = {
        let limits = VisionImageLimits()
        return TranscriptImageLoader.Budget(
            maximumSourcePixels: limits.maximumSourcePixels,
            maximumSourceDimension: limits.maximumSourceDimension,
            maximumDecodedBytes: limits.maximumDecodedBytes,
            allowedTypeIdentifiers: limits.allowedTypeIdentifiers)
    }()
}

private struct EmptyPlaceholderIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(.quaternary)
            .accessibilityHidden(true)
    }
}

private struct EmptyConversationLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        let iconSize = subviews[0].sizeThatFits(.unspecified)
        let iconCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        subviews[0].place(
            at: iconCenter,
            anchor: .center,
            proposal: ProposedViewSize(
                width: iconSize.width,
                height: iconSize.height))

        subviews[1].place(
            at: CGPoint(
                x: bounds.midX,
                y: iconCenter.y + iconSize.height / 2 + spacing),
            anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct LoadingModelText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationStart = Date()

    var body: some View {
        if reduceMotion {
            label(dotCount: 3)
        } else {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(animationStart))
                label(dotCount: Int(elapsed / 0.25) % 4)
            }
        }
    }

    private func label(dotCount: Int) -> some View {
        ZStack(alignment: .leading) {
            Text("Loading Model...").hidden()
            Text("Loading Model" + String(repeating: ".", count: dotCount))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Model")
    }
}

private struct IncrementalTranscriptView: NSViewRepresentable {
    var messages: [InstructionTranscriptMessage]
    var lastAnswer: String = ""
    var conversationPlainText: String = ""
    var requestNewChat: (() -> Void)?
    var prompt: String
    var images: [AppImageAttachment] = []
    var output: String
    var mailbox: GenerationTranscriptMailbox?
    var isTerminal: Bool
    var showsPrefillPlaceholder: Bool
    var runIdentity: Int
    var isOutputEdited = false

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var mailbox: GenerationTranscriptMailbox?
        var messages: [InstructionTranscriptMessage] = []
        var prompt = ""
        var promptPrefix = NSAttributedString()
        var promptPrefixIdentifier = ""

        /// The identifier the document controller is told about — empty until
        /// the prefix it names actually exists.
        ///
        /// `synchronize` records the new identifier and clears the prefix before
        /// starting the async image build, so telling the controller the final
        /// identifier up front made every term of its rebuild test false when
        /// the built prefix arrived: same prompt, same identifier, same response.
        /// The strip was dropped for the rest of the run, and a coordinator
        /// recreated against a finished transcript never drew images at all.
        ///
        /// `apply` reads this itself rather than taking it as an argument. It
        /// used to be passed in, and one of the three call sites passed the raw
        /// identifier instead — the same defect again, in the code written to
        /// prevent it. A caller that cannot name the identifier cannot get it
        /// wrong.
        var appliedPromptPrefixIdentifier: String {
            promptPrefix.length == 0 ? "" : promptPrefixIdentifier
        }
        var isTerminal = false
        var showsPrefillPlaceholder = false
        var runIdentity = 0
        /// Decides what the transcript owes the conversation; see
        /// `TranscriptSyncPlanner`.
        var planner = TranscriptSyncPlanner()
        /// Supplied by the pane so the transcript's menu can offer the whole
        /// chat and New chat without reaching back into SwiftUI state.
        var lastAnswer = ""
        var conversationPlainText = ""
        var requestNewChat: (() -> Void)?
        /// Holds the view at the bottom from the moment a run starts until its
        /// answer begins. One scroll is not enough: image thumbnails finish
        /// loading after it and push the content back down, which is exactly
        /// the case this exists for. The decision itself lives in
        /// `TranscriptScrollFollow`, where it can be tested.
        var follow = TranscriptScrollFollow()
        var isOutputEdited = false
        var timer: Timer?
        var prefillAnimationTimer: Timer?
        let documentController = InstructionTranscriptDocumentController()

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            // Right-click inside a turn offers that turn's answer, so a
            // transcript of several turns has an unambiguous copy affordance
            // rather than one floating button that reads as the first turn's.
            guard let transcript = textView as? TranscriptTextView else { return }
            transcript.answerAtCharacterIndex = { [weak self] index in
                self?.documentController.answer(at: index)
            }
            transcript.lastAnswerText = { [weak self] in self?.lastAnswer ?? "" }
            transcript.conversationText = { [weak self] in self?.conversationPlainText ?? "" }
            transcript.startNewChat = { [weak self] in self?.requestNewChat?() }
            guard timer == nil else { return }
            // Auto-follow yields the instant the reader scrolls. Without this,
            // holding the view at the bottom through prefill fought anyone
            // trying to look back at what they had sent.
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(readerTookOver),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(readerTookOver),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView)
            let timer = Timer(timeInterval: 0.1, target: self,
                              selector: #selector(drainMailbox),
                              userInfo: nil, repeats: true)
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func synchronize(
            messages: [InstructionTranscriptMessage],
            lastAnswer: String,
            conversationPlainText: String,
            requestNewChat: (() -> Void)?,
            prompt: String,
            images: [AppImageAttachment],
            output: String,
            mailbox: GenerationTranscriptMailbox?,
            isTerminal: Bool,
            showsPrefillPlaceholder: Bool,
            runIdentity: Int,
            isOutputEdited: Bool
        ) {
            // A new run always goes to the bottom, whatever the reader was
            // looking at: it is the thing they just asked for.
            let startedNewRun = runIdentity != self.runIdentity
            let firstSynchronize = self.runIdentity == 0 && planner.renderedHistory == 0
            self.runIdentity = runIdentity
            self.lastAnswer = lastAnswer
            self.conversationPlainText = conversationPlainText
            self.requestNewChat = requestNewChat
            _ = firstSynchronize
            let activeMailbox = isTerminal ? nil : mailbox
            self.mailbox = activeMailbox
            self.messages = messages
            self.prompt = prompt
            let prefixIdentifier = images.map {
                "\($0.id.uuidString):\($0.sha256)"
            }.joined(separator: ",")
            if prefixIdentifier != promptPrefixIdentifier {
                promptPrefixIdentifier = prefixIdentifier
                promptPrefix = NSAttributedString()
                buildPromptPrefix(images, identifier: prefixIdentifier)
            }
            self.isTerminal = isTerminal
            self.showsPrefillPlaceholder = showsPrefillPlaceholder
            self.isOutputEdited = isOutputEdited
            let response = InstructionTranscriptDocumentController
                .resolvedResponse(
                    output: output,
                    streamedResponse: activeMailbox?.drain().completeText,
                    isTerminal: isTerminal)
            apply(
                messages: messages,
                response: response,
                isTerminal: isTerminal,
                showsPrefillPlaceholder: showsPrefillPlaceholder,
                promptPrefix: promptPrefix,
                isOutputEdited: isOutputEdited)
            if startedNewRun { follow.beginRun() }
            // Once the answer has text, or the run is over, the reader is in
            // charge again; the usual follow-the-bottom rule takes over from a
            // view that is already at the bottom.
            if !response.isEmpty || isTerminal { follow.end() }
            if startedNewRun || shouldFollowNow() { scrollToBottom() }
        }

        /// Keeps the drawn document in step with the conversation.
        ///
        /// Three cases, and only the middle one happens per turn:
        /// a new chat clears everything; a new run seals the turn already drawn
        /// into the history above it; and a coordinator that has drawn nothing
        /// but finds a conversation already under way redraws that history once.
        /// Sealing is what keeps the cost per token proportional to the answer
        /// rather than to the whole conversation.
        /// Executes the planner's steps. The decisions themselves live in
        /// `TranscriptSyncPlanner`, where they are testable — three defects hid
        /// here precisely because nothing could reach them.
        private func adoptConversation(
            _ epoch: UUID,
            history: [(user: AppChatTurn, assistant: AppChatTurn)],
            contextBreak: Int?,
            startedNewRun: Bool,
            firstSynchronize: Bool
        ) {
            guard let textView, let storage = textView.textStorage else { return }
            let steps = planner.plan(TranscriptSyncPlanner.Input(
                epoch: epoch, historyCount: history.count, contextBreak: contextBreak,
                startedNewRun: startedNewRun, firstSynchronize: firstSynchronize))
            guard !steps.isEmpty else { return }

            storage.beginEditing()
            for step in steps {
                switch step {
                case .reset:
                    documentController.resetTranscript(storage: storage)
                    promptPrefixIdentifier = ""
                    promptPrefix = NSAttributedString()
                    prompt = ""
                case .sealDrawnTurn:
                    let before = documentController.frozenLength
                    documentController.sealTurn(storage: storage)
                    if documentController.frozenLength == before {
                        // It froze nothing, so the pair is still owed; consuming
                        // it would drop a turn that is in the KV from the
                        // transcript for good.
                        planner.sealFoundNothingToFreeze(historyCount: history.count)
                    }
                case .drawPair(let index):
                    guard index < history.count else { break }
                    let pair = history[index]
                    _ = documentController.synchronize(
                        storage: storage,
                        prompt: pair.user.text,
                        response: pair.assistant.text,
                        isTerminal: true,
                        // Cached thumbnails only. A history image whose
                        // thumbnail has not been decoded yet is dropped rather
                        // than blocking the redraw; the same degradation the
                        // live path already accepts.
                        promptPrefix: Self.makePromptPrefix(pair.user.images),
                        promptPrefixIdentifier: pair.user.images
                            .map { "\($0.id.uuidString):\($0.sha256)" }
                            .joined(separator: ","))
                    documentController.sealTurn(storage: storage)
                    prompt = ""
                    promptPrefixIdentifier = ""
                case .appendContextBreak:
                    let before = documentController.frozenLength
                    documentController.appendContextBreak(
                        storage: storage,
                        text: "Earlier turns are no longer in the model's context")
                    // Only marked when it actually wrote. Latching it on a
                    // refusal suppressed the break for the rest of the session.
                    if documentController.frozenLength != before {
                        planner.markContextBreakDrawn()
                    }
                }
            }
            storage.endEditing()
        }

        func scrollToBottom() {
            guard let textView else { return }
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            textView.scrollToEndOfDocument(nil)
            recordScrollPosition()
        }

        private func recordScrollPosition() {
            guard let scrollView else { return }
            follow.recordScroll(
                origin: scrollView.contentView.bounds.origin.y,
                documentHeight: scrollView.documentView?.bounds.height ?? 0)
        }

        private func shouldFollowNow() -> Bool {
            guard let scrollView else { return false }
            return follow.shouldScrollToBottom(
                origin: scrollView.contentView.bounds.origin.y,
                documentHeight: scrollView.documentView?.bounds.height ?? 0)
        }

        @objc private func drainMailbox() {
            // Keep the newest turn in view while its images lay out, even
            // between synchronize calls — but never against the reader.
            //
            // "Not at the bottom any more" is NOT the test for that. Images lay
            // out after the scroll and grow the document, which leaves the view
            // above the bottom through no act of the reader's; treating that as
            // a reader scroll ended the follow on exactly the turns that needed
            // it, and a prompt with several images stayed scrolled off the top.
            // A reader moving the view changes the scroll origin while the
            // document height stays put, so that is what ends it.
            if shouldFollowNow() { scrollToBottom() }
            guard let mailbox else { return }
            let snapshot = mailbox.drain()
            guard !snapshot.pendingText.isEmpty
                    || snapshot.completeText != documentController.response else {
                return
            }
            apply(messages: messages,
                  response: snapshot.completeText,
                  isTerminal: isTerminal,
                  showsPrefillPlaceholder: showsPrefillPlaceholder,
                  promptPrefix: promptPrefix,
                  isOutputEdited: isOutputEdited)
        }

        @objc private func animatePrefillPlaceholderIfNeeded() {
            guard documentController.showsPrefillPlaceholder,
                  let scrollView,
                  let textView,
                  let storage = textView.textStorage else { return }
            let wasAtBottom = isAtBottom(scrollView)
            let selection = textView.selectedRanges.map(\.rangeValue)

            storage.beginEditing()
            let changed = documentController.advancePrefillAnimation(storage: storage)
            storage.endEditing()
            guard changed else { return }

            let restored = InstructionTranscriptDocumentController.clampedRanges(
                selection,
                toLength: storage.length)
            if restored.isEmpty {
                textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            } else {
                textView.selectedRanges = restored.map(NSValue.init(range:))
            }
            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
                recordScrollPosition()
            }
        }

        @objc private func readerTookOver() {
            follow.end()
        }

        func invalidate() {
            NotificationCenter.default.removeObserver(self)
            timer?.invalidate()
            timer = nil
            stopPrefillAnimationTimer()
            mailbox = nil
        }

        private func updatePrefillAnimationTimer() {
            if documentController.showsPrefillPlaceholder {
                guard prefillAnimationTimer == nil else { return }
                let timer = Timer(
                    timeInterval: 0.25,
                    target: self,
                    selector: #selector(animatePrefillPlaceholderIfNeeded),
                    userInfo: nil,
                    repeats: true)
                timer.tolerance = 0.025
                RunLoop.main.add(timer, forMode: .common)
                prefillAnimationTimer = timer
            } else {
                stopPrefillAnimationTimer()
            }
        }

        private func stopPrefillAnimationTimer() {
            prefillAnimationTimer?.invalidate()
            prefillAnimationTimer = nil
        }

        private func apply(
            messages: [InstructionTranscriptMessage],
            response: String,
            isTerminal: Bool,
            showsPrefillPlaceholder: Bool,
            promptPrefix: NSAttributedString,
            isOutputEdited: Bool
        ) {
            guard let scrollView, let textView, let storage = textView.textStorage else { return }
            let wasAtBottom = isAtBottom(scrollView)
            let selection = textView.selectedRanges.map(\.rangeValue)

            storage.beginEditing()
            let update = documentController.synchronize(
                storage: storage,
                history: messages,
                response: response,
                isTerminal: isTerminal,
                showsPrefillPlaceholder: showsPrefillPlaceholder,
                promptPrefix: promptPrefix,
                promptPrefixIdentifier: appliedPromptPrefixIdentifier,
                isResponseEdited: isOutputEdited)
            storage.endEditing()
            updatePrefillAnimationTimer()

            guard update.mutation != .none else { return }
            // A rewritten stretch is different text, so a selection that
            // reached into it is dropped back to the boundary rather than
            // kept at its old length over characters it never covered.
            let adjusted = update.replaced.map {
                InstructionTranscriptDocumentController.adjustedRanges(
                    selection,
                    replacing: $0.previous,
                    newLength: $0.length)
            } ?? selection
            let restored = InstructionTranscriptDocumentController.clampedRanges(
                adjusted,
                toLength: storage.length)
            if restored.isEmpty {
                textView.setSelectedRange(NSRange(location: storage.length, length: 0))
            } else {
                textView.selectedRanges = restored.map(NSValue.init(range:))
            }
            if InstructionTranscriptDocumentController.shouldScrollToBottom(
                wasAtBottom: wasAtBottom,
                mutation: update.mutation
            ) {
                if let textContainer = textView.textContainer {
                    textView.layoutManager?.ensureLayout(for: textContainer)
                }
                textView.scrollToEndOfDocument(nil)
                // Every programmatic scroll updates the baseline, or the next
                // comparison reads our own move as the reader's.
                recordScrollPosition()
            }
        }

        private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let document = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= document.bounds.maxY - 24
        }

        /// Decoding the submitted images ran inside `updateNSView`'s render
        /// pass, so several photos near the decode budget stalled the window at
        /// the moment Run was pressed. Only the decode moves off the main
        /// thread — it lands in the loader's cache, and the attributed string is
        /// then assembled from cached copies, which is cheap and stays here
        /// where AppKit's drawing belongs. A prefix the transcript has since
        /// stopped wanting is dropped rather than applied. Images arriving after
        /// the first paint is the case `follow` already exists for.
        private func buildPromptPrefix(
            _ images: [AppImageAttachment], identifier: String
        ) {
            guard !images.isEmpty else { return }
            Task { [weak self] in
                await Task.detached(priority: .userInitiated) {
                    for attachment in images {
                        _ = SubmittedImageThumbnail.loadThumbnail(
                            at: attachment.fileURL,
                            maximumPixelSize: 720,
                            cacheKey: attachment.sha256)
                    }
                }.value
                guard let self, self.promptPrefixIdentifier == identifier else { return }
                let prefix = Self.makePromptPrefix(images)
                self.promptPrefix = prefix
                self.apply(
                    messages: self.messages,
                    response: self.documentController.response,
                    isTerminal: self.isTerminal,
                    showsPrefillPlaceholder: self.showsPrefillPlaceholder,
                    promptPrefix: prefix,
                    isOutputEdited: self.isOutputEdited)
                if self.shouldFollowNow() { self.scrollToBottom() }
            }
        }

        private static func makePromptPrefix(
            _ images: [AppImageAttachment]
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for attachment in images {
                // A refused or unreadable image is dropped from the transcript,
                // which is the same degradation the composer's placeholder tile
                // gives. The separator therefore keys off what has actually
                // been written, not off the attachment's index: keyed off the
                // index, a first image the decode budget refused left the line
                // starting with a bare gap.
                guard let image = SubmittedImageThumbnail.loadThumbnail(
                    at: attachment.fileURL,
                    maximumPixelSize: 720,
                    cacheKey: attachment.sha256) else { continue }
                image.size = SubmittedImageThumbnail.fittedSize(
                    image.size,
                    within: CGSize(width: 360, height: 240))
                let textAttachment = NSTextAttachment()
                textAttachment.attachmentCell = NSTextAttachmentCell(
                    imageCell: Self.rounded(image))
                if result.length > 0 {
                    result.append(NSAttributedString(string: "  "))
                }
                result.append(NSAttributedString(attachment: textAttachment))
            }
            return result
        }

        /// The transcript draws its images as text attachments, which cannot be
        /// clipped by the view the way the composer's thumbnails are, so the
        /// corners have to be drawn into the image itself.
        private static func rounded(_ image: NSImage) -> NSImage {
            let size = image.size
            guard size.width > 1, size.height > 1 else { return image }
            // Proportional rather than fixed, so a small thumbnail and a large
            // one look like the same shape; capped so wide images do not turn
            // into lozenges.
            let radius = min(12, min(size.width, size.height) * 0.08)
            let rounded = NSImage(size: size)
            rounded.lockFocus()
            defer { rounded.unlockFocus() }
            NSGraphicsContext.current?.imageInterpolation = .high
            let bounds = NSRect(origin: .zero, size: size)
            let path = NSBezierPath(roundedRect: bounds,
                                    xRadius: radius, yRadius: radius)
            path.addClip()
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
            return rounded
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = TranscriptTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.setAccessibilityLabel("Conversation transcript")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        context.coordinator.synchronize(
            messages: messages,
            lastAnswer: lastAnswer,
            conversationPlainText: conversationPlainText,
            requestNewChat: requestNewChat,
            prompt: prompt,
            images: images,
            output: output,
            mailbox: mailbox,
            isTerminal: isTerminal,
            showsPrefillPlaceholder: showsPrefillPlaceholder,
            runIdentity: runIdentity,
            isOutputEdited: isOutputEdited)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }
}

#if DEBUG
private struct TranscriptPreview: View {
    let response: String
    let isTerminal: Bool
    var showsPrefillPlaceholder = false

    var body: some View {
        IncrementalTranscriptView(
            messages: [
                InstructionTranscriptMessage(
                    role: .user,
                    content: "Explain this clearly."),
            ],
            prompt: "Explain this clearly.",
            output: response,
            mailbox: nil,
            isTerminal: isTerminal,
            showsPrefillPlaceholder: showsPrefillPlaceholder,
            runIdentity: 0)
            .padding(24)
            .frame(width: 720, height: 420)
    }
}

#Preview("Empty") {
    VStack(spacing: 8) {
        Image(systemName: "cube.transparent")
            .font(.title2)
            .foregroundStyle(.quaternary)
        Text("Start a chat, or choose a predefined example.")
            .font(.headline)
        Text("Each message keeps the ones before it in context.")
            .foregroundStyle(.secondary)
    }
    .frame(width: 720, height: 420)
}

#Preview("Streaming") {
    TranscriptPreview(
        response: "A response arriving one readable piece at a time...",
        isTerminal: false)
}

#Preview("Prefilling") {
    TranscriptPreview(
        response: "",
        isTerminal: false,
        showsPrefillPlaceholder: true)
}

#Preview("Completed prose") {
    TranscriptPreview(
        response: "# A clear answer\n\nHere is a concise explanation with **useful emphasis**.\n\n- First point\n- Second point",
        isTerminal: true)
}

#Preview("Completed code") {
    TranscriptPreview(
        response: "Use `fibonacci(7)`:\n\n```python\ndef fibonacci(n: int) -> list[int]:\n    return []\n```",
        isTerminal: true)
}

#Preview("Incomplete Markdown fallback") {
    TranscriptPreview(
        response: "The partial answer remains readable.\n\n```python\nprint('unfinished')",
        isTerminal: true)
}
#endif
