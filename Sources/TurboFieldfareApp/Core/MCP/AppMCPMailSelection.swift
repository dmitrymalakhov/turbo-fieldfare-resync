import Foundation
import Observation

public struct AppMCPMailContact: Codable, Equatable, Identifiable, Sendable {
    public var email: String
    public var name: String
    public var id: String { email }
    public init(email: String, name: String) { self.email = email.lowercased(); self.name = name }
}

public struct AppMCPMailGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var emails: Set<String>
    public init(id: UUID = UUID(), name: String, emails: Set<String>) {
        self.id = id; self.name = name; self.emails = Set(emails.map { $0.lowercased() })
    }
}

public struct AppMCPMailContacts: Codable, Equatable, Sendable {
    public var contacts: [AppMCPMailContact] = []
    public var groups: [AppMCPMailGroup] = []
    public var excludedEmails: Set<String> = []
    public init() {}

    public mutating func remember(_ headers: [AppMCPMailHeader]) {
        var known = Set(contacts.map(\.email))
        for header in headers where !header.sender.isEmpty {
            if known.insert(header.sender).inserted {
                contacts.append(.init(email: header.sender, name: header.senderName.isEmpty ? header.sender : header.senderName))
            }
        }
        contacts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Suggestions only: the user always reviews the resulting selection.
    /// This resolver never inspects bodies, invokes inference, or executes text from mail.
    public func suggest(prompt: String) -> Set<String> {
        let text = AppMCPMailIntent.normalize(prompt)
        let surnames = Dictionary(grouping: contacts, by: {
            AppMCPMailIntent.normalize($0.name).split(separator: " ").first.map(String.init) ?? ""
        }).mapValues(\.count)
        var emails = Set<String>()
        for group in groups where Self.mentions(group.name, in: text) { emails.formUnion(group.emails) }
        for contact in contacts {
            if Self.mentions(contact.email, in: text) || Self.mentions(contact.name, in: text) {
                emails.insert(contact.email)
            }
            // A unique surname can identify a contact without requiring the full name.
            let surname = AppMCPMailIntent.normalize(contact.name).split(separator: " ").first.map(String.init) ?? ""
            if surname.count >= 5, !surname.contains("@"), Self.surnameForms(surname).contains(where: { Self.mentions($0, in: text) }),
               surnames[surname] == 1 {
                emails.insert(contact.email)
            }
        }
        return emails.subtracting(excludedEmails)
    }

    private static func surnameForms(_ name: String) -> [String] {
        guard name.range(of: "^[а-я]+$", options: .regularExpression) != nil else { return [name] }
        if name.hasSuffix("ова") || name.hasSuffix("ева") || name.hasSuffix("ина") {
            let stem = String(name.dropLast())
            return [name, stem + "ой", stem + "у", stem + "ы", stem + "е"]
        }
        if name.hasSuffix("ов") || name.hasSuffix("ев") || name.hasSuffix("ин") {
            return [name, name + "а", name + "у", name + "ым", name + "е"]
        }
        return [name]
    }

    private static func mentions(_ name: String, in text: String) -> Bool {
        let normalized = AppMCPMailIntent.normalize(name)
        guard !normalized.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: normalized)
        return text.range(of: "(?<![\\p{L}\\p{N}_@.])" + escaped + "(?![\\p{L}\\p{N}_@.])", options: .regularExpression) != nil
    }
}

public struct AppMCPMailHeader: Identifiable, Equatable, Sendable {
    public let id: String
    public let changeKey: String?
    public let sender: String
    public let senderName: String
    public let subject: String
    public let date: String
    public init(id: String, changeKey: String? = nil, sender: String, senderName: String, subject: String, date: String) {
        self.id = id; self.changeKey = changeKey; self.sender = sender.lowercased()
        self.senderName = senderName; self.subject = subject; self.date = date
    }
}

public struct AppMCPMailPreview: Sendable {
    public let profileID: UUID
    public let period: String
    public let folder: String
    public let bounds: String
    public let headers: [AppMCPMailHeader]
    public let complete: Bool
    public init(profileID: UUID, period: String, folder: String, bounds: String,
                headers: [AppMCPMailHeader], complete: Bool) {
        self.profileID = profileID; self.period = period; self.folder = folder
        self.bounds = bounds; self.headers = headers; self.complete = complete
    }
    public func matching(senders: Set<String>, subject: String, excludedIDs: Set<String> = []) -> [AppMCPMailHeader] {
        headers.filter { senders.contains($0.sender) && !excludedIDs.contains($0.id)
            && (subject.isEmpty || $0.subject.localizedCaseInsensitiveContains(subject)) }
    }
}

public struct AppMCPMailReviewRequest: Identifiable, Sendable {
    public let id = UUID()
    public let profileName: String
    public let prompt: String
    public let preview: AppMCPMailPreview
    public let contacts: AppMCPMailContacts
    public let suggestedSenders: Set<String>
    public let suggestedSubject: String
    public init(profileName: String, prompt: String, preview: AppMCPMailPreview, contacts: AppMCPMailContacts) {
        self.profileName = profileName; self.prompt = prompt; self.preview = preview; self.contacts = contacts
        suggestedSenders = contacts.suggest(prompt: prompt)
        let expression = try? NSRegularExpression(pattern: #"(?:тем[аеуы]|subject)\s*(?:(?:содержит|contains)\s*)?:?\s*[«"]([^»"]+)[»"]"#, options: .caseInsensitive)
        if let match = expression?.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
           let range = Range(match.range(at: 1), in: prompt) { suggestedSubject = String(prompt[range]) }
        else { suggestedSubject = "" }
    }
}

public struct AppMCPMailSelection: Sendable {
    public let messageIDs: Set<String>
    public let senders: Set<String>
    public let subject: String
    public init(messageIDs: Set<String>, senders: Set<String>, subject: String = "") {
        self.messageIDs = messageIDs; self.senders = senders; self.subject = subject
    }
}

/// Owns only the pending choice. Cancellation must never release bodies to inference.
@MainActor @Observable
public final class AppMCPMailReviewCoordinator {
    public private(set) var pending: AppMCPMailReviewRequest?
    private var continuation: CheckedContinuation<AppMCPMailSelection, Error>?
    public init() {}
    public func request(_ request: AppMCPMailReviewRequest) async throws -> AppMCPMailSelection {
        try Task.checkCancellation()
        guard pending == nil else { throw AppMCPError.configuration("Заверши текущий выбор писем перед новым запросом.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; pending = request
            }
        } onCancel: {
            Task { @MainActor in self.cancel(request.id) }
        }
    }
    public func confirm(_ id: UUID, selection: AppMCPMailSelection) {
        guard let pending, pending.id == id else { return }
        guard selection.messageIDs.isSubset(of: Set(pending.preview.matching(senders: selection.senders, subject: selection.subject).map(\.id))) else { cancel(id); return }
        let completion = continuation; continuation = nil; self.pending = nil
        completion?.resume(returning: selection)
    }
    public func cancel(_ id: UUID) {
        guard pending?.id == id else { return }
        let completion = continuation; continuation = nil; pending = nil
        completion?.resume(throwing: CancellationError())
    }
}
