import TurboFieldfare

public struct AppContextUsage: Equatable, Sendable {
    public let promptTokens: Int
    public let maximumTokens: Int
    public let currentTurnTokens: Int?

    public init(promptTokens: Int,
                maximumTokens: Int,
                currentTurnTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.maximumTokens = maximumTokens
        self.currentTurnTokens = currentTurnTokens
    }

    public var remainingTokens: Int {
        max(0, maximumTokens - promptTokens)
    }

    public var overflowingTokens: Int {
        max(0, (currentTurnTokens ?? promptTokens) - maximumTokens)
    }

    public var isOverflowing: Bool {
        (currentTurnTokens ?? promptTokens) >= maximumTokens
    }

    public var requiresHistoryCompression: Bool {
        promptTokens >= maximumTokens && !isOverflowing
    }

    public var overLimitTokens: Int {
        max(0, promptTokens - maximumTokens)
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
            let currentTurnCount: Int?
            if count >= request.maxContextTokens,
               let currentTurn = messages.last {
                let renderedCurrentTurn = try tokenizer.applyChatTemplate(
                    [currentTurn])
                currentTurnCount = tokenizer.encode(
                    renderedCurrentTurn,
                    addBOS: false).count
            } else {
                currentTurnCount = nil
            }
            return AppContextUsage(
                promptTokens: count,
                maximumTokens: request.maxContextTokens,
                currentTurnTokens: currentTurnCount)
        }.value
    }
}
