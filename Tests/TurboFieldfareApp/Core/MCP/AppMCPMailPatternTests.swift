import Foundation
import Testing
@testable import TurboFieldfareAppCore

struct AppMCPMailPatternTests {
    private func mail(_ body: String, subject: String = "Обсуждение") -> AppMCPStoredMail {
        .init(profileID: UUID(), header: .init(id: "a", sender: "other@example.com", senderName: "Малахов", subject: subject, date: "2026-09-11T12:00:00+03:00"), folder: "Inbox", body: body)
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }
    @Test func combinesTaskDeadlineIdentityAndCustomPhrases() {
        let identity = AppMCPMailIdentity(name: "Дмитрий", surname: "Малахов", aliases: "Дмитрию, Дима")
        var filter = AppMCPMailPatternFilter()
        filter.assignments = true; filter.mentionsMe = true; filter.deadlines = true
        filter.deadlineThrough = date(2026, 9, 18)
        #expect(filter.matches(mail("Прошу Малахова подготовить отчет. Срок: 18 сентября 2026."), identity: identity))
        #expect(!filter.matches(mail("Прошу Малахова подготовить отчет до 19.09.2026."), identity: identity))
        #expect(!filter.matches(mail("Прошу Иванова подготовить отчет до 18.09.2026."), identity: identity))
        #expect(!filter.matches(mail("Прошу Малахова подготовить отчет до 18.09.2026."), identity: nil))
        filter.phrases = "согласовать, подготовить отчет"
        #expect(filter.matches(mail("Дмитрию: прошу подготовить отчет, срок: 18.09.2026."), identity: identity))
        filter.phrases = "бюджет, презентация"
        #expect(!filter.matches(mail("Прошу Малахова подготовить отчет до 18.09.2026."), identity: identity))
    }
    @Test func mentionRequiresWholeWordAndDoesNotMatchSenderMetadata() {
        var filter = AppMCPMailPatternFilter(); filter.mentionsMe = true
        let identity = AppMCPMailIdentity(surname: "Малахов")
        #expect(!filter.matches(mail("Малаховский район"), identity: identity))
        #expect(!filter.matches(mail("Новости"), identity: identity))
        #expect(filter.matches(mail("Согласовано с Малаховым."), identity: identity))
    }
    @Test func datesNeedCueAndUseMessageYearAndRelativeDay() {
        let source = "2026-09-11"
        #expect(AppMCPMailPatternFilter.deadlineDates(in: "Срок: завтра", sentDate: source) == [date(2026, 9, 12)])
        #expect(AppMCPMailPatternFilter.deadlineDates(in: "до 18 сентября", sentDate: source) == [date(2026, 9, 18)])
        #expect(AppMCPMailPatternFilter.deadlineDates(in: "к 2026-09-18", sentDate: source) == [date(2026, 9, 18)])
        #expect(AppMCPMailPatternFilter.deadlineDates(in: "до 31.02.2026", sentDate: source).isEmpty)
        #expect(AppMCPMailPatternFilter.deadlineDates(in: "Получено 18.09.2026", sentDate: source).isEmpty)
        #expect(AppMCPMailPatternFilter.deadlineDates(in: "до завтра", sentDate: "unknown").isEmpty)
    }
    @Test func identityRoundTripsAndOlderContactsStillDecode() throws {
        let old = Data(#"{"contacts":[],"groups":[],"excludedEmails":[]}"#.utf8)
        var contacts = try JSONDecoder().decode(AppMCPMailContacts.self, from: old)
        #expect(contacts.identity == nil)
        contacts.identity = .init(name: "Дмитрий", surname: "Малахов", aliases: "Дима")
        #expect(try JSONDecoder().decode(AppMCPMailContacts.self, from: JSONEncoder().encode(contacts)) == contacts)
    }
}
