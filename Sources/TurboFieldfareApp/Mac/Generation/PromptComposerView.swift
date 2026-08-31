import AppKit
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

struct PromptComposerView: View {
    @Bindable var model: AppModel
    @FocusState private var promptFocused: Bool
    @State private var showingPromptTips = false
    @State private var isImportingDocuments = false
    @State private var isExtractingDocuments = false
    @State private var documentImportError: String?
    @State private var previewedAttachment: AppPromptAttachment?
    @State private var contextUsage: AppContextUsage?
    @State private var isEstimatingContext = false
    @State private var showingContextDashboard = false
    @State private var showingConversationMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.promptAttachments.isEmpty {
                attachments
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
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
        }
        .fileImporter(
            isPresented: $isImportingDocuments,
            allowedContentTypes: DocumentTextExtractor.supportedContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleDocumentSelection)
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
        TextEditor(text: $model.promptText)
            .accessibilityLabel("Prompt")
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($promptFocused)
            .onKeyPress(.return, phases: [.down, .repeat]) { keyPress in
                switch PromptSubmissionPolicy.decision(
                    newlineShortcut: model.newlineShortcut,
                    modifiers: keyPress.modifiers,
                    canRun: model.canSubmitPrompt,
                    hasMarkedText: promptHasMarkedText,
                    isRepeat: keyPress.phase.contains(.repeat)) {
                case .submit:
                    model.submitPrompt()
                    return .handled
                case .consume:
                    return .handled
                case .deferToEditor:
                    return .ignored
                }
            }
            .frame(height: editorHeight)
            .overlay(alignment: .topLeading) {
                if model.promptText.isEmpty {
                    // Matches the NSTextView text origin: 5pt line fragment
                    // padding, no vertical inset.
                    Text("Prompt")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    private var promptHasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
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
            attachDocumentAction
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

    private var attachments: some View {
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

    private var attachDocumentAction: some View {
        Button {
            documentImportError = nil
            isImportingDocuments = true
        } label: {
            Group {
                if isExtractingDocuments {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Attach documents", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!model.canEditSelectedChat || isExtractingDocuments)
        .help("Attach text, PDF, Word, PowerPoint, or Excel files")
        .accessibilityLabel(isExtractingDocuments
                            ? "Extracting document text"
                            : "Attach documents")
    }

    private var promptTips: some View {
        Button {
            showingPromptTips.toggle()
        } label: {
            Label("Prompt tips", systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Prompt tips")
        .popover(isPresented: $showingPromptTips,
                 attachmentAnchor: .point(.top),
                 arrowEdge: .top) {
            promptGuide
        }
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
        if !model.promptText.isEmpty {
            Button {
                model.promptText = ""
                promptFocused = true
            } label: {
                Label("Clear prompt", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help("Clear prompt")
        }
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
