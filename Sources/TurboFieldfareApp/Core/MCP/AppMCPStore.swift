import Foundation
import Security

@MainActor
public protocol AppMCPSecretStoring {
    func read(id: UUID) throws -> AppMCPCredentials
    func write(_ credentials: AppMCPCredentials, id: UUID) throws
    func remove(id: UUID) throws
}

@MainActor
public final class AppMCPKeychainStore: AppMCPSecretStoring {
    private let service = "TurboFieldfare.MCP"
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public func read(id: UUID) throws -> AppMCPCredentials {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return AppMCPCredentials() }
        guard status == errSecSuccess, let data = item as? Data else { throw AppMCPError.keychain(status) }
        return try JSONDecoder().decode(AppMCPCredentials.self, from: data)
    }
    public func write(_ credentials: AppMCPCredentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppMCPError.keychain(added) }
        } else if status != errSecSuccess { throw AppMCPError.keychain(status) }
    }
    public func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppMCPError.keychain(status) }
    }
}

public struct AppMCPProfileStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurboFieldfare", isDirectory: true)
    }
    private struct Envelope: Codable { var version = 1; var profiles: [AppMCPProfile] }
    public func load() throws -> [AppMCPProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, Set(envelope.profiles.map(\.id)).count == envelope.profiles.count else {
            throw AppMCPError.configuration("The saved connections file has an unsupported format. It was left unchanged.")
        }
        return envelope.profiles
    }
    public func save(_ profiles: [AppMCPProfile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Envelope(profiles: profiles)).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
