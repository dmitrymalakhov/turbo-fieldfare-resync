public enum AppSentPromptBehavior: String, CaseIterable, Codable, Sendable, Identifiable {
    case clear
    case keep

    public var id: String { rawValue }

    public var settingsLabel: String {
        switch self {
        case .clear: return "Clear Draft"
        case .keep: return "Keep Draft"
        }
    }
}
