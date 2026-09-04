#if os(macOS)
import Foundation

@MainActor
public final class AppMCPPromptContextProvider: AppPromptContextProviding {
    private let manager: AppMCPManager
    public init(manager: AppMCPManager) { self.manager = manager }

    public func prepare(prompt: String, recentUserPrompts: [String],
                        progress: @escaping @MainActor (String) -> Void) async throws -> AppExternalPromptContext? {
        let directIntent = try AppMCPMailIntent.resolve(prompt)
        guard let intent = try directIntent ?? AppMCPMailIntent.resolve(prompt, previousUserPrompt: recentUserPrompts.last) else { return nil }
        let profiles = manager.profiles.filter { $0.kind == .exchange }
        guard !profiles.isEmpty else {
            throw AppMCPError.configuration("Добавь почтовый сервер в MCP Connections → Add MCP Server → Microsoft Exchange. Затем повтори запрос в чате.")
        }
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
        progress("Читаю почту: \(intent.periodLabel)…")
        let snapshot = try await manager.readMail(profile.id, period: intent.period, folder: intent.folder) { count in
            progress("Читаю почту: \(intent.periodLabel) · \(count) писем")
        }
        try Task.checkCancellation()
        let summary = "Почта: \(profile.name) · \(intent.periodLabel) · \(intent.folder) · \(snapshot.count) писем"
            + (snapshot.complete ? "" : " · загружена часть периода")
        return AppExternalPromptContext(
            attachment: AppPromptAttachment(fileName: summary, formatLabel: "Mail", extractedText: snapshot.text,
                                            wasTruncatedDuringExtraction: !snapshot.complete),
            summary: summary)
    }
}
#endif
