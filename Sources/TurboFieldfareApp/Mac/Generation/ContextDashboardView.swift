import Foundation
import TurboFieldfareAppCore
import SwiftUI

struct ContextDashboardView: View {
    let model: AppModel
    let usage: AppContextUsage?
    let isEstimating: Bool
    let showMemory: () -> Void
    let branchChat: () -> Void
    let startCleanChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            capacity
            Divider()
            composition
            notice
            Divider()
            actions
        }
        .padding(18)
        .frame(width: 390, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Context for the Next Message")
                    .font(.headline)
                Text(model.selectedChat.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var capacity: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: usage.fraction)
                    .progressViewStyle(.linear)
                    .tint(capacityTint(usage))
                HStack(alignment: .firstTextBaseline) {
                    Text(capacityTitle(usage))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(capacityTint(usage))
                    Spacer()
                    Text(
                        "\(usage.promptTokens.formatted()) / "
                            + "\(usage.maximumTokens.formatted()) tokens")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(capacityDetail(usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 9) {
                if isEstimating {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "text.cursor")
                        .foregroundStyle(.secondary)
                }
                Text(isEstimating
                     ? "Estimating context use…"
                     : "Write a prompt to see exact token use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included context")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            contextRow(
                icon: "bubble.left.and.bubble.right",
                title: "Recent conversation",
                value: messageCountLabel(recentMessageCount))

            if compressedMessageCount > 0 {
                Button(action: showMemory) {
                    contextRow(
                        icon: "brain",
                        title: "Compressed memory",
                        value: "\(compressedMessageCount) earlier messages",
                        showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .help("View the memory used instead of older full messages")
            }

            if savedDocumentMessageCount > 0 {
                contextRow(
                    icon: "doc.text",
                    title: "Documents in recent context",
                    value: messageCountLabel(savedDocumentMessageCount))
            }

            if !model.promptAttachments.isEmpty {
                contextRow(
                    icon: "paperclip",
                    title: "Documents in this draft",
                    value: attachmentValue)
            }

            if !model.promptText.isEmpty {
                contextRow(
                    icon: "square.and.pencil",
                    title: "Current draft",
                    value: characterCountLabel(model.promptText.count))
            }
        }
    }

    private func contextRow(
        icon: String,
        title: String,
        value: String,
        showsDisclosure: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.callout)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var notice: some View {
        if let usage, usage.isOverflowing {
            contextNotice(
                icon: "exclamationmark.triangle.fill",
                text: overflowNotice(usage),
                color: .red)
        } else if let usage, usage.requiresHistoryCompression {
            contextNotice(
                icon: "brain.fill",
                text: "The current turn fits. Older full messages will be "
                    + "replaced by compact memory before generation.",
                color: .orange)
        } else if let usage, usage.fraction >= 0.85 {
            contextNotice(
                icon: "exclamationmark.circle.fill",
                text: "Little context remains for the answer. "
                    + "Shorten the draft, remove a document, or start a clean chat.",
                color: .orange)
        } else if compressedMessageCount > 0 {
            contextNotice(
                icon: "checkmark.circle.fill",
                text: "Older turns stay visible in the transcript and are sent as compact memory.",
                color: .secondary)
        }
    }

    private func contextNotice(
        icon: String,
        text: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 9))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button(
                "Branch Conversation",
                systemImage: "arrow.triangle.branch",
                action: branchChat)
                .disabled(model.selectedChat.messages.isEmpty
                          || !model.canEditSelectedChat)
            Button(
                "New Clean Chat",
                systemImage: "sparkles",
                action: startCleanChat)
                .disabled(!model.canNavigateChats)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var compressedMessageCount: Int {
        guard model.selectedChat.contextSummary?.isEmpty == false,
              let boundaryID = model.selectedChat.summarizedThroughMessageID,
              let boundaryIndex = model.selectedChat.messages.firstIndex(where: {
                  $0.id == boundaryID
              }) else {
            return 0
        }
        return boundaryIndex + 1
    }

    private var recentMessageCount: Int {
        max(0, model.selectedChat.messages.count - compressedMessageCount)
    }

    private var savedDocumentMessageCount: Int {
        model.selectedChat.messages.dropFirst(compressedMessageCount).filter {
            $0.contextContent != $0.content
        }.count
    }

    private var attachmentValue: String {
        let tokens = model.promptAttachments.reduce(0) {
            $0 + $1.approximateTokenCount
        }
        return "\(model.promptAttachments.count) · ≈\(compactTokens(tokens)) tokens"
    }

    private func capacityTint(_ usage: AppContextUsage) -> Color {
        if usage.isOverflowing { return .red }
        if usage.requiresHistoryCompression || usage.fraction >= 0.85 {
            return .orange
        }
        return Color.accentColor
    }

    private func capacityTitle(_ usage: AppContextUsage) -> String {
        if usage.isOverflowing { return "Does not fit" }
        if usage.requiresHistoryCompression { return "History will compress" }
        if usage.fraction >= 0.85 { return "Almost full" }
        return "\(Int((usage.fraction * 100).rounded()))% used"
    }

    private func capacityDetail(_ usage: AppContextUsage) -> String {
        if usage.isOverflowing { return overflowNotice(usage) }
        if usage.requiresHistoryCompression {
            return "The unsummarized conversation is about "
                + "\(usage.overLimitTokens.formatted()) tokens over the window."
        }
        return "About \(usage.remainingTokens.formatted()) tokens remain "
            + "for the response. The estimate includes chat formatting."
    }

    private func overflowNotice(_ usage: AppContextUsage) -> String {
        if usage.overflowingTokens > 0 {
            return "The current turn is about "
                + "\(usage.overflowingTokens.formatted()) tokens over the selected window."
        }
            return "The request fills the selected window, leaving no capacity "
                + "to decode an answer."
    }

    private func messageCountLabel(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }

    private func characterCountLabel(_ count: Int) -> String {
        count == 1 ? "1 character" : "\(count.formatted()) characters"
    }

    private func compactTokens(_ value: Int) -> String {
        value >= 1_024
            ? String(format: "%.1fK", Double(value) / 1_024)
            : "\(value)"
    }
}
