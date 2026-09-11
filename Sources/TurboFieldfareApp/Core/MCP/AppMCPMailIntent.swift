import Foundation

public struct AppMCPMailIntent: Equatable, Sendable {
    public let period: String
    public let folder: String
    public var periodLabel: String {
        switch period { case "yesterday": "вчера"; case "this_week": "текущая неделя"; default: "сегодня" }
    }

    /// With a saved selection, ordinary questions use that conversation's mail.
    /// Only an explicit refresh/new period starts another mailbox selection.
    public static func requestsFreshMail(_ prompt: String) -> Bool {
        let text = normalize(prompt)
        if matches(#"\b(?:загрузи|загрузить|обнови|обновить|перезагрузи|проверь\s+почту|проверить\s+почту|fetch|reload|refresh)\b"#, text)
            || matches(#"\b(?:новые|свежие|другие|new|latest)\s+(?:письма|письм|сообщения|emails?|mail)\b"#, text) { return true }
        if matches(#"\b(?:этих|эти|этом|этого|выбранн\p{L}*|загруженн\p{L}*|выгруженн\p{L}*|прочитанн\p{L}*|these|loaded|selected)\b"#, text) { return false }
        return matches(#"\b(?:сегодня|вчера|недел\p{L}*|месяц\p{L}*|позавчера|today|yesterday|week|month)\b"#, text)
    }

    /// Conservative routing for direct mail requests, independent of model text
    /// and tool annotations. Ambiguous/unsupported dates fail before mailbox access.
    public static func resolve(_ prompt: String, previousUserPrompt: String? = nil) throws -> Self? {
        let text = normalize(prompt)
            .replacingOccurrences(of: #"(?s)```.*?```|«[^»]*»|"[^"]*"|“[^”]*”"#, with: " ", options: .regularExpression)
        let mail = containsMail(text)
        let followup = previousUserPrompt.map { containsMail(normalize($0)) } == true
            && matches(#"^(?:(?:а|и|тогда)\s+)?(?:(?:что (?:важного|нового|пришло)|what about)\s+)?(?:(?:за|на)\s+)?(?:сегодня|вчера|(?:(?:эту|текущую)\s+)?неделю|today|yesterday|this week)\s*[?!.]*$"#, text)
        guard mail || followup else { return nil }
        if matches(#"\b(?:как\s+(?:подключ\p{L}*|настро\p{L}*|работа\p{L}*)|что\s+(?:значит|означает|такое)|how\s+(?:to|does)|what\s+(?:does|is)|пример\p{L}*|переведи|translate)\b"#, text)
            || matches(#"\b(?:не\s+(?:читай|проверяй|загружай|обращайся)|(?:do not|don't)\s+(?:read|check|load))\b"#, text)
            // Drafting instructions may include an infinitive, style, or "текст письма".
            // Dates in the supplied draft must not turn it into a mailbox request.
            || matches(#"\b(?:напиши|написать|составь|составить|отредактируй|отредактировать|перепиши|переписать|исправь|исправить|сформулируй|сформулировать|write|draft|rewrite|edit|rephrase|proofread)\s+(?:(?:мне|пожалуйста|официальн\p{L}*|делов\p{L}*|коротк\p{L}*|вежлив\p{L}*|формальн\p{L}*|a|an|the|my|this|formal|professional|polite|short)\s+)*(?:письмо|ответ|черновик|текст|email|e-mail|reply|message|text)\b"#, text)
            || matches(#"\b(?:приложенн\p{L}*|загруженн\p{L}*|attached|loaded|these)\b"#, text) { return nil }
        if matches(#"\b(?:удали|удалить|перемести|пометь|отметь|отправь|отправить|delete|remove|move|mark|send)\b"#, text) {
            throw AppMCPError.configuration("Exchange подключён только для чтения. Изменение и отправка писем недоступны.")
        }
        let today = matches(#"\b(?:сегодня|сегодняшн\p{L}*|today)\b"#, text)
        let yesterday = matches(#"\b(?:вчера|вчерашн\p{L}*|yesterday)\b"#, text)
        let week = matches(#"\b(?:недел\p{L}*|week)\b"#, text)
        let read = matches(#"\b(?:покажи|разбери|проанализируй|прочитай|проверь|загрузи|загрузить|обнови|обновить|перезагрузи|fetch|reload|refresh|сводк\p{L}*|обзор|важн\p{L}*|пришл\p{L}*|приходил\p{L}*|получил\p{L}*|summary|summari[sz]e|show|read|check|review|analy[sz]e)\b"#, text)
        if matches(#"\b(?:прошл\p{L}*|предыдущ\p{L}*|последн\p{L}*|позавчера|завтра|месяц\p{L}*|last|previous|month|tomorrow)\b|\d\s*(?:дн\p{L}*|day\p{L}*)|\d{1,4}[./-]\d{1,2}|\bс\s+понедельника\s+по\b"#, text) {
            throw AppMCPError.configuration("Для загрузки из сообщения пока доступны: сегодня, вчера или текущая неделя с понедельника. Уточни период в запросе.")
        }
        guard today || yesterday || week || read else { return nil }
        guard [today, yesterday, week].filter({ $0 }).count <= 1 else {
            throw AppMCPError.configuration("Укажи один период загрузки: сегодня, вчера или текущая неделя.")
        }
        var folder = matches(#"\b(?:отправленн\p{L}*|исходящ\p{L}*|sent)\b"#, text) ? "Sent" : "Inbox"
        let folderPattern = #"(?:папк\p{L}*|folder)\s+[«"]([^»"]+)[»"]"#
        if let regex = try? NSRegularExpression(pattern: folderPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
           let range = Range(match.range(at: 1), in: prompt) {
            folder = String(prompt[range])
        } else if matches(#"\b(?:папк\p{L}*|folders?)\b"#, text) {
            throw AppMCPError.configuration("Укажи одну папку в кавычках, например: письма за сегодня из папки «Проект». По умолчанию читаются входящие.")
        }
        return Self(period: yesterday ? "yesterday" : week ? "this_week" : "today", folder: folder)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func containsMail(_ text: String) -> Bool {
        matches(#"\b(?:почт(?:а|у|ы|е|ой|ою)|письм(?:о|а|у|ом|е|ам|ами|ах)|писем|e-?mails?|mail|inbox)\b|\bпочтов\p{L}*\s+ящик\p{L}*\b|\bвходящие\s+(?:за\s+)?(?:сегодня|вчера|неделю|эту|текущую)\b"#, text)
    }
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
