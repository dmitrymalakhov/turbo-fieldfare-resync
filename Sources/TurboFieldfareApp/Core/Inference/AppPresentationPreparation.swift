import Foundation

public enum AppPresentationPreparation {
    public static let prompt = """
    Turn your immediately preceding answer into a presentation draft.

    Requirements:
    - Use the same language as the source answer.
    - Create 8 to 12 slides unless the material clearly needs fewer.
    - Start with a minimal title slide and end with conclusions or next steps.
    - For every content slide, provide a short audience-facing title and no more than five concise bullets.
    - Add one brief "Suggested visual" line only when a visual would materially improve the slide.
    - Add compact speaker notes after each slide.
    - Preserve the source facts and numbers. Do not invent missing evidence.
    - Return only the presentation draft in Markdown, using "# Slide N - Title" headings.
    """

    public static func title(from sourceTitle: String) -> String {
        let suffix = " - presentation"
        let maximumBaseLength = max(0, 80 - suffix.count)
        let base = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBase = base.isEmpty ? "Presentation" : base
        return String(resolvedBase.prefix(maximumBaseLength)) + suffix
    }
}
