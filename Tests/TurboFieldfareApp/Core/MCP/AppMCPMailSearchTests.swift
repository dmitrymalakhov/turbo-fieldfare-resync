import Foundation
import Testing
@testable import TurboFieldfareAppCore

struct AppMCPMailSearchTests {
    @Test func quotedPhrasesExclusionsAndAnyWord() {
        let query = AppMCPMailSearchQuery(#""план релиза" отчет -рассылка -"не актуально""#)
        #expect(query.terms == ["план релиза", "отчет"])
        #expect(query.excluded == ["рассылка", "не актуально"])
        #expect(query.matches("План релиза и отчёт"))
        #expect(!query.matches("План нового релиза и отчет"))
        #expect(!query.matches("План релиза, отчет. Уже не актуально"))
        #expect(AppMCPMailSearchQuery("бюджет релиз", anyTerm: true).matches("релиз завтра"))
        #expect(!AppMCPMailSearchQuery("бюджет релиз").matches("релиз завтра"))
        #expect(AppMCPMailSearchQuery("-рассылка").matches("поручение"))
        #expect(AppMCPMailSearchQuery("-рассылка").hits(in: "поручение").isEmpty)
    }
    @Test func rangesReferToOriginalUnicodeAndAllOccurrences() throws {
        let text = "👩🏽‍💻 Прошу: отчёт. ОТЧЕТ! e\u{301}"
        let hits = AppMCPMailSearchQuery("отчет").hits(in: text)
        #expect(hits.count == 2)
        #expect(hits.map { (text as NSString).substring(with: $0.range) } == ["отчёт", "ОТЧЕТ"])
        let accent = AppMCPMailSearchQuery("é").hits(in: text)
        #expect(accent.count == 1)
        #expect(Range(try #require(accent.first).range, in: text) != nil)
    }
    @Test func patternsExplainWhyMessageMatched() {
        let text = "👋 Малахову: просьба согласовать отчёт, срок: 18 сентября 2026."
        let identity = AppMCPMailIdentity(surname: "Малахов")
        var filter = AppMCPMailPatternFilter()
        filter.assignments = true; filter.deadlines = true; filter.mentionsMe = true
        let hits = filter.hits(in: text, identity: identity, sentDate: "2026-09-11")
        #expect(Set(hits.map(\.kind)) == [.assignment, .deadline, .identity])
        #expect(hits.contains { (text as NSString).substring(with: $0.range) == "Малахову" })
        #expect(hits.contains { (text as NSString).substring(with: $0.range) == "срок: 18 сентября 2026" })
        #expect(hits.allSatisfy { Range($0.range, in: text) != nil })
    }
    @Test func weekdaysAndRelativeDaysUseMessageDate() {
        let dates = AppMCPMailPatternFilter.deadlineDates(in: "Срок: через 3 дня; к понедельнику; до пятницы", sentDate: "2026-09-11")
        let calendar = Calendar(identifier: .gregorian)
        #expect(dates.map { calendar.component(.day, from: $0) } == [14, 14, 11])
    }
}
