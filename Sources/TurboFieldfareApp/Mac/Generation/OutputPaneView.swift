import AppKit
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
        .onChange(of: model.presentationExportRequest) { _, request in
            guard let request else { return }
            exportPresentation(
                title: request.title,
                response: request.markdown)
            model.consumePresentationExportRequest(id: request.id)
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

            Button("Export Response as PDF…", action: exportResponsePDF)
                .disabled(model.outputResponsePlainText.isEmpty
                          || model.isSelectedChatRunning)

            Button("Create PowerPoint with Local Model") {
                model.preparePresentationFromResponse()
            }
            .disabled(!model.canPreparePresentationFromResponse)

            Button("Export Response as PowerPoint…", action: exportResponsePPTX)
                .disabled(model.outputResponsePlainText.isEmpty
                          || model.isSelectedChatRunning)

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
            HStack {
                Spacer()
                transcriptActions
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            if model.isSelectedChatRunning {
                IncrementalTranscriptView(
                    messages: model.transcriptBaseMessages.map { message in
                        InstructionTranscriptMessage(
                            role: message.role == .user ? .user : .assistant,
                            content: message.content,
                            isEdited: isEditedAssistantMessage(message))
                    },
                    output: model.outputText,
                    mailbox: model.generationTranscriptMailbox,
                    isTerminal: false,
                    showsPrefillPlaceholder: model.outputResponsePlainText.isEmpty,
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
                responseExportMenu
                copyResponseButton
            }
        }
    }

    private var responseExportMenu: some View {
        Menu {
            Button("Export Response as PDF…", action: exportResponsePDF)
                .disabled(model.isSelectedChatRunning)
            Button("Create PowerPoint with Local Model") {
                model.preparePresentationFromResponse()
            }
            .disabled(!model.canPreparePresentationFromResponse)
            Button("Export Response as PowerPoint…", action: exportResponsePPTX)
                .disabled(model.isSelectedChatRunning)
            Divider()
            Button("Export Conversation…", action: exportConversation)
        } label: {
            Image(systemName: "square.and.arrow.up")
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
        .help("Export this answer as PDF or PowerPoint")
        .accessibilityLabel("Response export options")
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
        .disabled(!model.canEditSelectedChat)
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
        .disabled(!model.canEditSelectedChat)
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
                            ? "Copy response"
                            : "Response copied")
        .accessibilityHint("Copies only the generated answer")
        .help(responseCopyFeedbackID == nil
              ? "Copy response"
              : "Response copied")
    }

    private var emptyPlaceholderContent: some View {
        VStack(spacing: 8) {
            if !needsModelLoad {
                Text("Choose a predefined example or write your own prompt.")
                    .font(.headline)
                Text("Describe the goal, relevant context, and any constraints.")
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

    private func exportResponsePDF() {
        let panel = NSSavePanel()
        panel.title = "Export Response as PDF"
        panel.nameFieldStringValue = model.selectedChat.title + ".pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ResponsePDFExporter.makePDF(
                title: model.selectedChat.title,
                response: model.outputResponsePlainText)
            try data.write(to: url, options: .atomic)
        } catch {
            model.error = .unknown("Response could not be exported as PDF: \(error.localizedDescription)")
        }
    }

    private func exportResponsePPTX() {
        exportPresentation(
            title: model.selectedChat.title,
            response: model.outputResponsePlainText)
    }

    private func exportPresentation(title: String, response: String) {
        let panel = NSSavePanel()
        panel.title = "Export Response as PowerPoint"
        panel.nameFieldStringValue = safeFileName(title) + ".pptx"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "pptx") ?? .data,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ResponsePPTXExporter.makePPTX(
                title: title,
                response: response)
            try data.write(to: url, options: .atomic)
        } catch {
            model.error = .unknown(
                "Response could not be exported as PowerPoint: \(error.localizedDescription)")
        }
    }

    private func safeFileName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "presentation" : cleaned
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
    var output: String
    var mailbox: GenerationTranscriptMailbox?
    var isTerminal: Bool
    var showsPrefillPlaceholder: Bool
    var isOutputEdited = false

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var mailbox: GenerationTranscriptMailbox?
        var messages: [InstructionTranscriptMessage] = []
        var isTerminal = false
        var showsPrefillPlaceholder = false
        var isOutputEdited = false
        var timer: Timer?
        var prefillAnimationTimer: Timer?
        let documentController = InstructionTranscriptDocumentController()

        func attach(scrollView: NSScrollView, textView: NSTextView) {
            self.scrollView = scrollView
            self.textView = textView
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.1, target: self,
                              selector: #selector(drainMailbox),
                              userInfo: nil, repeats: true)
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func synchronize(
            messages: [InstructionTranscriptMessage],
            output: String,
            mailbox: GenerationTranscriptMailbox?,
            isTerminal: Bool,
            showsPrefillPlaceholder: Bool,
            isOutputEdited: Bool
        ) {
            let activeMailbox = isTerminal ? nil : mailbox
            self.mailbox = activeMailbox
            self.messages = messages
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
                isOutputEdited: isOutputEdited)
        }

        @objc private func drainMailbox() {
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
            if wasAtBottom { textView.scrollToEndOfDocument(nil) }
        }

        func invalidate() {
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
                isResponseEdited: isOutputEdited)
            storage.endEditing()
            updatePrefillAnimationTimer()

            guard update.mutation != .none else { return }
            let restored = InstructionTranscriptDocumentController.clampedRanges(
                selection,
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
            }
        }

        private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
            guard let document = scrollView.documentView else { return true }
            let visible = scrollView.contentView.bounds
            return visible.maxY >= document.bounds.maxY - 24
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
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
            output: output,
            mailbox: mailbox,
            isTerminal: isTerminal,
            showsPrefillPlaceholder: showsPrefillPlaceholder,
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
            output: response,
            mailbox: nil,
            isTerminal: isTerminal,
            showsPrefillPlaceholder: showsPrefillPlaceholder)
            .padding(24)
            .frame(width: 720, height: 420)
    }
}

#Preview("Empty") {
    VStack(spacing: 8) {
        Image(systemName: "cube.transparent")
            .font(.title2)
            .foregroundStyle(.quaternary)
        Text("Choose a predefined example or write your own prompt.")
            .font(.headline)
        Text("Describe the goal, relevant context, and any constraints.")
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
