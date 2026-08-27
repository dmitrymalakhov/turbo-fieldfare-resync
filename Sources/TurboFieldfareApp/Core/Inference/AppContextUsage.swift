import TurboFieldfare

public struct AppContextUsage: Equatable, Sendable {
    public let promptTokens: Int
    public let maximumTokens: Int

    public init(promptTokens: Int, maximumTokens: Int) {
        self.promptTokens = promptTokens
        self.maximumTokens = maximumTokens
    }

    public var remainingTokens: Int {
        max(0, maximumTokens - promptTokens)
    }

    public var fraction: Double {
        guard maximumTokens > 0 else { return 0 }
        return min(max(Double(promptTokens) / Double(maximumTokens), 0), 1)
    }
}

public enum AppContextUsageEstimator {
    public static func estimate(
        _ request: AppGenerationRequest
    ) async throws -> AppContextUsage {
        try await Task.detached(priority: .userInitiated) {
            let tokenizer = try await GFTokenizer.load(
                forModelDirectory: request.modelDirectory)
            try Task.checkCancellation()
            let messages = request.messages.map { message in
                let role: GFTokenizer.Role = switch message.role {
                case .system: .system
                case .user: .user
                case .assistant: .assistant
                }
                return GFTokenizer.Message(role: role, content: message.content)
            }
            let rendered = try tokenizer.applyChatTemplate(messages)
            let count = tokenizer.encode(rendered, addBOS: false).count
            return AppContextUsage(
                promptTokens: count,
                maximumTokens: request.maxContextTokens)
        }.value
    }
}
