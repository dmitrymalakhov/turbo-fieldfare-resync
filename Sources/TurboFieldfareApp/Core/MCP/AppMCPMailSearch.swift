import Foundation

public struct AppMCPMailSearchHit: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case query = "Поиск", assignment = "Поручение", deadline = "Срок", identity = "Обо мне", phrase = "Фраза"
    }
    /// UTF-16 offsets in the original, unmodified text, including emoji and accented characters.
    public var range: NSRange
    public var kind: Kind
    public init(range: NSRange, kind: Kind) { self.range = range; self.kind = kind }
    public static func literal(_ term: String, in text: String, kind: Kind) -> [Self] {
        guard !term.isEmpty else { return [] }
        var hits: [Self] = [], remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
            hits.append(.init(range: NSRange(range, in: text), kind: kind))
            remaining = range.upperBound..<text.endIndex
        }
        return hits
    }
    public static func regex(_ pattern: String, in text: String, kind: Kind) -> [Self] {
        let pattern = pattern.replacingOccurrences(of: "е", with: "[её]")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .filter { $0.range.length > 0 }.map { .init(range: $0.range, kind: kind) }
    }
    public static func ordered(_ hits: [Self]) -> [Self] {
        var seen = Set<String>()
        return hits.sorted { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }
            .filter { seen.insert("\($0.range.location):\($0.range.length):\($0.kind.rawValue)").inserted }
    }
}

/// Literal query grammar: words, quoted phrases, and -excluded words/phrases.
public struct AppMCPMailSearchQuery: Sendable {
    public var terms: [String] = []
    public var excluded: [String] = []
    public var anyTerm: Bool
    public init(_ query: String, anyTerm: Bool = false) {
        self.anyTerm = anyTerm
        let regex = try! NSRegularExpression(pattern: #"(-?)(?:"([^"]+)"|(\S+))"#)
        for match in regex.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            func part(_ n: Int) -> String? { Range(match.range(at: n), in: query).map { String(query[$0]) } }
            guard let term = part(2) ?? part(3), !term.isEmpty else { continue }
            if part(1) == "-" { excluded.append(term) } else { terms.append(term) }
        }
    }
    public func matches(_ text: String) -> Bool {
        func contains(_ term: String) -> Bool { text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        guard !excluded.contains(where: contains) else { return false }
        return terms.isEmpty || (anyTerm ? terms.contains(where: contains) : terms.allSatisfy(contains))
    }
    public func hits(in text: String) -> [AppMCPMailSearchHit] {
        AppMCPMailSearchHit.ordered(terms.flatMap { AppMCPMailSearchHit.literal($0, in: text, kind: .query) })
    }
}
