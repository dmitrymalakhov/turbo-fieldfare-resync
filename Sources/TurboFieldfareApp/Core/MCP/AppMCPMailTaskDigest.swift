import Foundation

/// Verbatim candidates from a message, not generated tasks or inferred assignees.
public struct AppMCPMailTaskDigest: Sendable {
    public var requests: [String]
    public var deadlineEvidence: [String]
    public init(_ mail: AppMCPStoredMail) {
        let separator = try! NSRegularExpression(pattern: #"\n+|(?<=[.!?])\s+(?=[А-ЯA-Z])"#)
        let text = mail.body
        var start = text.startIndex, passages: [String] = []
        for match in separator.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            passages.append(String(text[start..<range.lowerBound])); start = range.upperBound
        }
        passages.append(String(text[start...]))
        passages = passages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var taskFilter = AppMCPMailPatternFilter(); taskFilter.assignments = true
        var deadlineFilter = AppMCPMailPatternFilter(); deadlineFilter.deadlines = true
        var seen = Set<String>()
        requests = passages.filter { !taskFilter.hits(in: $0, identity: nil, sentDate: mail.header.date).isEmpty && seen.insert($0).inserted }
        if requests.isEmpty, !taskFilter.hits(in: mail.header.subject, identity: nil, sentDate: mail.header.date).isEmpty {
            requests = [mail.header.subject]
        }
        seen = []
        deadlineEvidence = ([mail.header.subject] + passages).filter {
            !deadlineFilter.hits(in: $0, identity: nil, sentDate: mail.header.date).isEmpty && seen.insert($0).inserted
        }
    }
}
