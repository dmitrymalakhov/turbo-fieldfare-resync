import Foundation
import Testing
@testable import TurboFieldfareAppCore

@MainActor @Suite
struct AppMCPMailArchiveTests {
    @Test func persistsFullBodiesAndSearchesWithinAccountAndGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.json")
        let archive = AppMCPMailArchive(fileURL: url)
        let first = UUID(), second = UUID()
        let header = AppMCPMailHeader(id: "same-id", sender: "anna@example.com", senderName: "Анна", subject: "План", date: "2026-09-11")
        try archive.upsert([.init(profileID: first, header: header, folder: "Inbox", body: "Бюджет утверждён. Срок — пятница."),
                            .init(profileID: second, header: header, folder: "Inbox", body: "Другой аккаунт")])
        #expect(archive.search("БЮДЖЕТ пятница", profileID: first, senders: ["anna@example.com"]).count == 1)
        #expect(archive.search("бюджет", profileID: second).isEmpty)
        #expect(archive.search("бюджет", senders: []).isEmpty)
        #expect(archive.search("anna план").count == 2)
        try archive.upsert([.init(profileID: first, header: header, folder: "Inbox", body: "Обновлённый полный текст")])
        let reopened = AppMCPMailArchive(fileURL: url)
        #expect(reopened.messages.count == 2)
        #expect(reopened.search("бюджет").isEmpty)
        #expect(reopened.search("полный").first?.body == "Обновлённый полный текст")
        try reopened.remove(ids: Set(reopened.search("полный").map(\.id)))
        #expect(AppMCPMailArchive(fileURL: url).messages.count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func corruptArchiveIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("invalid".utf8); try original.write(to: url)
        let archive = AppMCPMailArchive(fileURL: url)
        #expect(archive.error != nil)
        #expect(throws: (any Error).self) { try archive.upsert([]) }
        #expect(try Data(contentsOf: url) == original)
    }
}
