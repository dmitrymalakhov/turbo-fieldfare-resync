import Foundation

public enum AppMCPKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case exchange, smtp, stdio
    public var id: String { rawValue }
    public var title: String { self == .smtp ? "SMTP Mail" : (self == .exchange ? "Exchange Mail" : "Local MCP Server") }
    public var symbol: String { self == .stdio ? "puzzlepiece.extension" : "envelope" }
    public var isMail: Bool { self != .stdio }
}

public struct AppMCPProfile: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "Exchange"
    public var kind: AppMCPKind = .exchange
    public var executable = ""
    public var pythonExecutable: String?
    public var arguments: [String] = []
    public var workingDirectory = ""
    public var server = ""
    public var email = ""
    public var username = ""
    public var authType = "NTLM"
    public var timezone = "Europe/Moscow"
    public var certificateBundle = ""
    public var smtpPort: Int?
    public var smtpSecurity: String?
    public var effectiveSMTPPort: Int { smtpPort ?? 587 }
    public var effectiveSMTPSecurity: String { smtpSecurity ?? "STARTTLS" }
    /// Public certificates selected for this connection; no private keys or identities.
    public var selectedCertificates: AppMCPCertificateSelection?
    public var environmentKeys: [String] = []
    public var enabledTools: Set<String> = []
    public init(kind: AppMCPKind = .exchange) {
        self.kind = kind
        if kind == .smtp { name = "SMTP"; pythonExecutable = "/usr/bin/python3"; enabledTools = ["check_connection"] }
        else if kind == .stdio { name = "Local MCP Server" }
        else { enabledTools = ["list_messages", "get_message", "list_calendar_events"] }
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppMCPError.configuration("Enter a connection name.")
        }
        if kind.isMail {
            guard !server.isEmpty, !server.contains("://"), !server.contains("/"),
                  !server.contains(where: \.isWhitespace) else {
                throw AppMCPError.configuration("Enter the mail host, for example mail.company.com, without a URL scheme or a path.")
            }
            guard email.contains("@"), !username.isEmpty else {
                throw AppMCPError.configuration("Enter your mailbox address and sign-in username.")
            }
            if kind == .smtp {
                guard (1...65535).contains(effectiveSMTPPort), ["STARTTLS", "TLS"].contains(effectiveSMTPSecurity),
                      pythonExecutable?.hasPrefix("/") == true,
                      !server.contains(":"), !server.contains("\0"),
                      !email.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
                    throw AppMCPError.configuration("Enter a SMTP hostname, port 1–65535, STARTTLS or TLS, sender address and absolute Python 3 path.")
                }
            } else if !["NTLM", "BASIC"].contains(authType) || TimeZone(identifier: timezone) == nil {
                throw AppMCPError.configuration("Choose a valid authentication method and time zone.")
            }
            if let selectedCertificates {
                guard certificateBundle.isEmpty else {
                    throw AppMCPError.configuration("Choose one certificate source for this connection.")
                }
#if os(macOS)
                try AppMCPCertificates.validate(AppMCPCertificates.inspect(selectedCertificates))
#endif
            }
        } else {
            guard executable.hasPrefix("/") else {
                throw AppMCPError.configuration("Choose an executable using its full path.")
            }
        }
        guard Set(environmentKeys).count == environmentKeys.count,
              environmentKeys.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.contains("\0") }) else {
            throw AppMCPError.configuration("Environment variable names must be unique and contain no equals sign.")
        }
    }
}

/// This value is stored only in Keychain, never in the profile JSON or a prompt.
public struct AppMCPCredentials: Codable, Equatable, Sendable {
    public var password = ""
    public var environment: [String: String] = [:]
    public init(password: String = "", environment: [String: String] = [:]) {
        self.password = password
        self.environment = environment
    }
}

public struct AppMCPTool: Equatable, Identifiable, Sendable {
    public var name: String
    public var description: String
    public var readOnly: Bool
    public var schema: AppMCPValue
    public var id: String { name }
    public init(name: String, description: String = "", readOnly: Bool = false,
                schema: AppMCPValue = .object([:])) {
        self.name = name; self.description = description; self.readOnly = readOnly; self.schema = schema
    }
}

public enum AppMCPStatus: Equatable, Sendable {
    case disconnected, checkingPython, installing, connecting, authenticating, connected, failed(String)
    public var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .checkingPython: "Checking Python…"
        case .installing: "Installing connector…"
        case .connecting: "Connecting…"
        case .authenticating: "Checking mailbox access…"
        case .connected: "Connected"
        case .failed: "Connection failed"
        }
    }
    public var isBusy: Bool {
        switch self { case .checkingPython, .installing, .connecting, .authenticating: true; default: false }
    }
}

public enum AppMCPError: LocalizedError {
    case configuration(String), disconnected, timeout, protocolError, serverRejected, keychain(Int32)
    public var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .disconnected: "The MCP process stopped. Reconnect to try again."
        case .timeout: "The server did not respond in time. Check its address, VPN and network connection."
        case .protocolError: "The server returned an unsupported MCP response. Check the executable and its version."
        case .serverRejected: "The request failed. For Exchange, check your sign-in details, VPN and trusted corporate certificate."
        case .keychain(let code): "Keychain could not access the saved credentials (code \(code))."
        }
    }
}

public enum AppMCPValue: Codable, Equatable, Sendable {
    case object([String: AppMCPValue]), array([AppMCPValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: AppMCPValue].self) { self = .object(v) }
        else { self = .array(try c.decode([AppMCPValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> AppMCPValue? { objectValue?[key] }
    public var objectValue: [String: AppMCPValue]? { if case .object(let v) = self { v } else { nil } }
    public var arrayValue: [AppMCPValue]? { if case .array(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var intValue: Int? {
        guard case .number(let v) = self, v.isFinite, v >= Double(Int.min), v < Double(Int.max), v.rounded() == v else { return nil }
        return Int(v)
    }
}
