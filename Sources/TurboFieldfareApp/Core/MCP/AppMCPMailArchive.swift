import Foundation
import Observation

public struct AppMCPStoredMail: Codable, Identifiable, Equatable, Sendable {
    public var profileID: UUID
    public var header: AppMCPMailHeader
    public var folder: String
    public var body: String
    public var id: String { profileID.uuidString + ":" + header.id }
    public init(profileID: UUID, header: AppMCPMailHeader, folder: String, body: String) {
        self.profileID = profileID; self.header = header; self.folder = folder; self.body = body
    }
    public var referenceText: String {
        "Subject: \(header.subject)\nFrom: \(header.senderName) <\(header.sender)>\nDate: \(header.date)\nFolder: \(folder)\nBody:\n\(body)"
    }
}

/// A local archive of explicitly downloaded bodies; searches never contact the server.
@MainActor @Observable
public final class AppMCPMailArchive {
    public private(set) var messages: [AppMCPStoredMail] = []
    public private(set) var error: String?
    private let fileURL: URL
    private var readable = true
    private struct Envelope: Codable { var version = 1; var messages: [AppMCPStoredMail] }
    public init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let saved = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
                guard saved.version == 1, Set(saved.messages.map(\.id)).count == saved.messages.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                messages = saved.messages
            }
        } catch { readable = false; self.error = "Не удалось открыть архив почты. Исходный файл сохранён: \(fileURL.path)" }
    }
    public func upsert(_ incoming: [AppMCPStoredMail]) throws {
        var updated = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for mail in incoming { updated[mail.id] = mail }
        try save(updated.values.sorted { $0.header.date == $1.header.date ? $0.id < $1.id : $0.header.date > $1.header.date })
    }
    public func remove(ids: Set<String>) throws { try save(messages.filter { !ids.contains($0.id) }) }
    private func save(_ updated: [AppMCPStoredMail]) throws {
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Envelope(messages: updated))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        messages = updated
    }
    public func search(_ query: String, profileID: UUID? = nil, senders: Set<String>? = nil) -> [AppMCPStoredMail] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return messages.filter { mail in
            if let profileID, mail.profileID != profileID { return false }
            if let senders, !senders.contains(mail.header.sender.lowercased()) { return false }
            let text = "\(mail.header.senderName) \(mail.header.sender) \(mail.header.subject) \(mail.body)"
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
