import Testing
import Foundation
@testable import TurboFieldfareAppCore

struct AppMCPMailTaskDigestTests {
    @Test func extractsVerbatimRequestsAndSeparateDeadlineWithoutModel() {
        let mail = AppMCPStoredMail(profileID: UUID(), header: .init(id: "1", sender: "a@example.com", senderName: "Анна", subject: "Проект", date: "2026-09-11"), folder: "Inbox",
            body: "Добрый день.\nПрошу согласовать план.\nСрок: 18.09.2026.\nПожалуйста, пришлите отчет.\nПрошу согласовать план.\nСпасибо.")
        let digest = AppMCPMailTaskDigest(mail)
        #expect(digest.requests == ["Прошу согласовать план.", "Пожалуйста, пришлите отчет."])
        #expect(digest.deadlineEvidence == ["Срок: 18.09.2026."])
        #expect(digest.requests.allSatisfy { mail.body.contains($0) })
    }
    @Test func absenceAndSubjectFallbackDoNotInventTasks() {
        var mail = AppMCPStoredMail(profileID: UUID(), header: .init(id: "1", sender: "a@example.com", senderName: "Анна", subject: "Новости", date: "2026-09-11"), folder: "Inbox", body: "Добрый день. Спасибо!")
        #expect(AppMCPMailTaskDigest(mail).requests.isEmpty)
        #expect(AppMCPMailTaskDigest(mail).deadlineEvidence.isEmpty)
        mail.header = .init(id: "1", sender: "a@example.com", senderName: "Анна", subject: "Просьба согласовать план", date: "2026-09-11")
        #expect(AppMCPMailTaskDigest(mail).requests == ["Просьба согласовать план"])
    }
}
