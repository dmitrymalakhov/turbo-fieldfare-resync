#if os(macOS)
import Foundation

@MainActor
public final class AppMCPPromptContextProvider: AppPromptContextProviding {
    private let manager: AppMCPManager
    private let review: @MainActor (AppMCPMailReviewRequest) async throws -> AppMCPMailSelection
    public init(manager: AppMCPManager,
                review: (@MainActor (AppMCPMailReviewRequest) async throws -> AppMCPMailSelection)? = nil) {
        self.manager = manager
        self.review = review ?? { try await manager.mailReview.request($0) }
    }

    public func prepare(prompt: String, recentUserPrompts: [String],
                        progress: @escaping @MainActor (String) -> Void) async throws -> AppExternalPromptContext? {
        try await prepare(prompt: prompt, recentUserPrompts: recentUserPrompts,
                          hasLoadedMail: recentUserPrompts.contains { $0.contains("[Почта:") }, progress: progress)
    }

    public func prepare(prompt: String, recentUserPrompts: [String], hasLoadedMail: Bool,
                        progress: @escaping @MainActor (String) -> Void) async throws -> AppExternalPromptContext? {
        if hasLoadedMail, !AppMCPMailIntent.requestsFreshMail(prompt) { return nil }
        // Mail routing is an optional enhancement. Without a configured Exchange
        // profile, every prompt belongs to the ordinary local-model chat, including
        // prompts that contain words such as "mail" or "почта".
        let profiles = manager.profiles.filter { $0.kind == .exchange }
        guard !profiles.isEmpty else { return nil }

        let directIntent = try AppMCPMailIntent.resolve(prompt)
        guard let intent = try directIntent ?? AppMCPMailIntent.resolve(prompt, previousUserPrompt: recentUserPrompts.last) else { return nil }
        let normalized = AppMCPMailIntent.normalize(prompt)
        let named = profiles.filter {
            [$0.name, $0.email].contains { !$0.isEmpty && normalized.contains(AppMCPMailIntent.normalize($0)) }
        }
        let previous = directIntent == nil ? profiles.filter {
            recentUserPrompts.last?.contains("[Почта: \($0.name) ·") == true
        } : []
        let candidates = !named.isEmpty ? named : !previous.isEmpty ? previous : profiles
        guard candidates.count == 1, let profile = candidates.first else {
            throw AppMCPError.configuration("Подключено несколько почтовых ящиков. Укажи имя подключения в сообщении: " + profiles.map(\.name).joined(separator: ", "))
        }
        guard profile.enabledTools.isSuperset(of: ["list_messages", "get_message"]) else {
            throw AppMCPError.configuration("Чтение писем отключено для \(profile.name). Включи list_messages и get_message в настройках этого подключения.")
        }
        try Task.checkCancellation()
        progress("Подключение к \(profile.name)…")
        try await manager.ensureConnected(profile.id)
        progress("Собираю отправителей: \(intent.periodLabel)…")
        let preview = try await manager.previewMail(profile.id, period: intent.period, folder: intent.folder) { count in
            progress("Собираю заголовки: \(intent.periodLabel) · \(count) писем")
        }
        let contacts = manager.profiles.first(where: { $0.id == profile.id })?.mailContacts ?? .init()
        progress("Выбери письма для анализа…")
        let selection = try await review(.init(profileName: profile.name, prompt: prompt, preview: preview, contacts: contacts))
        try Task.checkCancellation()
        let snapshot = try await manager.readSelectedMail(preview, selection: selection) { count in
            progress("Читаю выбранные письма: \(count) из \(selection.messageIDs.count)")
        }
        try Task.checkCancellation()
        let summary = "Почта: \(profile.name) · \(intent.periodLabel) · \(intent.folder) · \(snapshot.count) писем"
            + (snapshot.bodyCharacterCount.map { " · \($0) символов текста" } ?? "")
            + (snapshot.complete ? "" : " · загружена часть периода")
            + " · тексты сохранены в диалоге"
        return AppExternalPromptContext(
            attachment: AppPromptAttachment(fileName: summary, formatLabel: "Mail", extractedText: snapshot.text,
                                            wasTruncatedDuringExtraction: !snapshot.complete),
            summary: summary)
    }
}
#endif
