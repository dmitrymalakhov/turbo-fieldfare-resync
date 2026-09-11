import Foundation

public struct AppMCPMailIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var surname: String
    public var aliases: String
    public init(name: String = "", surname: String = "", aliases: String = "") {
        self.name = name; self.surname = surname; self.aliases = aliases
    }
    public var referenceText: String { "User identity for this mailbox: \(name) \(surname). Alternative names: \(aliases). A mention alone does not prove a task was assigned to the user." }
    public var terms: [String] {
        let raw = [name, surname] + aliases.components(separatedBy: ",")
        return raw.flatMap { value -> [String] in
            let word = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
            guard !word.isEmpty else { return [] }
            if word.hasSuffix("ов") || word.hasSuffix("ев") || word.hasSuffix("ин") {
                return [word, word + "а", word + "у", word + "ым", word + "е"]
            }
            if word.hasSuffix("ова") || word.hasSuffix("ева") || word.hasSuffix("ина") {
                let stem = word.dropLast(); return [word, stem + "ой", stem + "у", stem + "ы", stem + "е"]
            }
            return [word]
        }
    }
}

/// Transparent candidate filters, not semantic assignment or deadline verification.
public struct AppMCPMailPatternFilter: Equatable, Sendable {
    public var assignments = false
    public var deadlines = false
    public var mentionsMe = false
    public var phrases = ""
    public var deadlineThrough: Date?
    public init() {}
    public func matches(_ mail: AppMCPStoredMail, identity: AppMCPMailIdentity?) -> Bool {
        let text = (mail.header.subject + "\n" + mail.body).lowercased().replacingOccurrences(of: "ё", with: "е")
        if assignments && AppMCPMailSearchHit.regex(Self.assignmentPattern, in: text, kind: .assignment).isEmpty { return false }
        if deadlines && AppMCPMailSearchHit.regex(Self.deadlinePattern, in: text, kind: .deadline).isEmpty { return false }
        if mentionsMe {
            guard let identity, identity.terms.contains(where: { Self.has("(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\p{L}\\p{N}_])", text) }) else { return false }
        }
        let alternatives = phrases.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !alternatives.isEmpty && !alternatives.contains(where: { text.localizedCaseInsensitiveContains($0.replacingOccurrences(of: "ё", with: "е")) }) { return false }
        if let deadlineThrough {
            let limit = Self.calendar.startOfDay(for: deadlineThrough)
            guard Self.deadlineDates(in: text, sentDate: mail.header.date).contains(where: { $0 <= limit }) else { return false }
        }
        return true
    }
    public func hits(in text: String, identity: AppMCPMailIdentity?, sentDate: String) -> [AppMCPMailSearchHit] {
        var hits: [AppMCPMailSearchHit] = []
        if assignments { hits += AppMCPMailSearchHit.regex(Self.assignmentPattern, in: text, kind: .assignment) }
        if deadlines || deadlineThrough != nil {
            hits += AppMCPMailSearchHit.regex(Self.deadlinePattern, in: text, kind: .deadline)
            hits += AppMCPMailSearchHit.regex(Self.datePattern, in: text, kind: .deadline).filter { hit in
                guard let range = Range(hit.range, in: text) else { return false }
                return Self.deadlineDates(in: String(text[range]), sentDate: sentDate).contains { date in
                    deadlineThrough.map { date <= Self.calendar.startOfDay(for: $0) } ?? true
                }
            }
        }
        if mentionsMe, let identity {
            for term in identity.terms {
                hits += AppMCPMailSearchHit.regex("(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}_])", in: text, kind: .identity)
            }
        }
        for phrase in phrases.components(separatedBy: ",") {
            hits += AppMCPMailSearchHit.literal(phrase.trimmingCharacters(in: .whitespacesAndNewlines), in: text, kind: .phrase)
        }
        return AppMCPMailSearchHit.ordered(hits)
    }
    static let assignmentPattern = #"\b(прошу|просим|просьба|пожалуйста|ожидаем|ждем|поруч\p{L}*|необходимо|нужно|требуется|сдела\p{L}*|подготов\p{L}*|согласу\p{L}*|согласова\p{L}*|провер\p{L}*|уточни\p{L}*|пришли\p{L}*|заполни\p{L}*|обнови\p{L}*|предостав\p{L}*|направ\p{L}*|ответственн\p{L}*|action\s+required|please|assigned)\b"#
    static let deadlinePattern = #"\b(срок\p{L}*|дедлайн\p{L}*|deadline|due|не\s+позднее|до\s+(?:\d+|завтра|конца|понедельника|вторника|среды|четверга|пятницы|субботы|воскресенья)|к\s+(?:\d+|понедельнику|вторнику|среде|четвергу|пятнице|субботе|воскресенью)|через\s+\d+\s+(?:день|дня|дней)|сегодня|завтра|послезавтра|eod)\b"#
    private static func has(_ pattern: String, _ text: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = .current; return value }

    private static let datePattern = #"\b(?:до|к|не\s+позднее|срок\p{L}*|дедлайн|deadline|due)\s*(?:[:—-]\s*)?(?:(\d{4})-(\d{2})-(\d{2})|(\d{1,2})[./](\d{1,2})(?:[./](\d{4}))?|(\d{1,2})\s+(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)(?:\s+(\d{4}))?|(сегодня|завтра|послезавтра|понедельника|понедельнику|вторника|вторнику|среды|среде|четверга|четвергу|пятницы|пятнице|субботы|субботе|воскресенья|воскресенью|через\s+\d{1,3}\s+(?:день|дня|дней)))(?![\p{L}\p{N}]|[./]\d)"#

    /// Explicit dates after a deadline cue; omitted years and relative days use the message date.
    public static func deadlineDates(in raw: String, sentDate: String) -> [Date] {
        let text = raw.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cal = calendar
        let source = String(sentDate.prefix(10))
        let parts = source.split(separator: "-").compactMap { Int($0) }
        let reference = parts.count == 3 ? cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) : nil
        let months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"]

        guard let regex = try? NSRegularExpression(pattern: datePattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func group(_ n: Int) -> String? { Range(match.range(at: n), in: text).map { String(text[$0]) } }
            if let relative = group(10), let reference {
                let days: Int
                if relative.hasPrefix("через"), let count = relative.split(whereSeparator: \.isWhitespace).compactMap({ Int($0) }).first {
                    days = count
                } else if let weekday = ["понедельника": 2, "понедельнику": 2, "вторника": 3, "вторнику": 3,
                                          "среды": 4, "среде": 4, "четверга": 5, "четвергу": 5,
                                          "пятницы": 6, "пятнице": 6, "субботы": 7, "субботе": 7,
                                          "воскресенья": 1, "воскресенью": 1][relative] {
                    days = (weekday - cal.component(.weekday, from: reference) + 7) % 7
                } else { days = relative == "сегодня" ? 0 : relative == "завтра" ? 1 : 2 }
                return cal.date(byAdding: .day, value: days, to: reference)
            }
            let year = group(1).flatMap(Int.init) ?? group(6).flatMap(Int.init) ?? group(9).flatMap(Int.init) ?? reference.map { cal.component(.year, from: $0) }
            let month = group(2).flatMap(Int.init) ?? group(5).flatMap(Int.init) ?? group(8).flatMap { months.firstIndex(of: $0).map { $0 + 1 } }
            let day = group(3).flatMap(Int.init) ?? group(4).flatMap(Int.init) ?? group(7).flatMap(Int.init)
            guard let year, let month, let day, let date = cal.date(from: DateComponents(year: year, month: month, day: day)),
                  cal.component(.year, from: date) == year, cal.component(.month, from: date) == month, cal.component(.day, from: date) == day else { return nil }
            return date
        }
    }
}
