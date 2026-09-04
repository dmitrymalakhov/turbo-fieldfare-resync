import Foundation

public struct AppExternalPromptContext: Sendable {
    public let attachment: AppPromptAttachment
    public let summary: String
    public init(attachment: AppPromptAttachment, summary: String) {
        self.attachment = attachment; self.summary = summary
    }
}

/// Resolves explicit requests for external reference data before inference.
/// Receives user-visible prompts only; attached documents and service responses
/// must never become instructions to call another service.
@MainActor
public protocol AppPromptContextProviding: AnyObject {
    func prepare(prompt: String, recentUserPrompts: [String],
                 progress: @escaping @MainActor (String) -> Void) async throws -> AppExternalPromptContext?
}
