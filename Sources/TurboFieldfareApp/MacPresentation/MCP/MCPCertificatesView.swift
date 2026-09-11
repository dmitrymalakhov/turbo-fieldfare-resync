import AppKit
import SwiftUI
import TurboFieldfareAppCore
import UniformTypeIdentifiers

struct MCPCertificateSettingsView: View {
    @Binding var profile: AppMCPProfile
    @State private var choosingKeychain = false
    @State private var error: String?
    @State private var certificatePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection = profile.selectedCertificates {
                Label("\(selection.certificates.count) certificate(s) · \(selection.source)", systemImage: "checkmark.shield")
                    .fontWeight(.medium)
                if let certificates = try? AppMCPCertificates.inspect(selection) {
                    ForEach(certificates) { certificate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(certificate.name).fontWeight(.medium)
                            Text(certificate.kindDescription).font(.caption).foregroundStyle(.secondary)
                            Text("Issuer: \(certificate.issuer)").font(.caption).foregroundStyle(.secondary)
                            Text("Expires \(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("SHA-256 fingerprint") {
                                Text(certificate.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                            }.font(.caption)
                            if let issue = certificate.validityIssue { Text(issue).font(.caption).foregroundStyle(.red) }
                        }
                    }
                } else {
                    Text("The saved certificate cannot be read. Choose it again.").foregroundStyle(.red)
                }
            } else if !profile.certificateBundle.isEmpty {
                Label("Previously selected CA bundle", systemImage: "doc.badge.gearshape")
                Text(profile.certificateBundle).font(.caption).textSelection(.enabled)
            } else {
                Label("Default CA certificates", systemImage: "shield")
                Text("Python uses its own CA bundle. If your corporate certificate is installed in macOS, select it from Keychain below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose from Keychain…", systemImage: "key.horizontal") { choosingKeychain = true }
                Button("Choose File…", systemImage: "doc") { chooseFile() }
            }
            Text("Certificate file path").font(.callout.weight(.medium))
            HStack {
                TextField("/etc/ssl/cert.pem", text: $certificatePath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Certificate file path")
                Button("Load File") { loadCertificatePath() }
                    .disabled(certificatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Enter a PEM, CER, CRT or DER file path and click Load File. Certificates are copied into this connection; load the file again after renewal.")
                .font(.caption).foregroundStyle(.secondary)
            if profile.selectedCertificates != nil || !profile.certificateBundle.isEmpty {
                Button("Use Default Certificates") { select(nil) }.buttonStyle(.link)
            }
            Text("The selected certificates are trusted only for this Exchange connection. TLS checks stay enabled. Keychain trust settings are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: $choosingKeychain) {
            MCPKeychainCertificatePicker(host: profile.server) { select($0) }
        }
    }

    private func select(_ selection: AppMCPCertificateSelection?) {
        profile.selectedCertificates = selection; profile.certificateBundle = ""; error = nil
    }

    private func loadCertificatePath() {
        let path = (certificatePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            error = "Enter an absolute certificate file path, such as /etc/ssl/cert.pem."
            return
        }
        do {
            select(try AppMCPCertificates.readFile(URL(fileURLWithPath: path)))
            certificatePath = path
        } catch { self.error = error.localizedDescription }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Exchange certificates"
        panel.message = "Choose a CA bundle or self-signed server certificate (PEM, CER, CRT or DER). Private keys and P12/PFX identities are not needed."
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["pem", "cer", "crt", "der"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { select(try AppMCPCertificates.readFile(url)) }
        catch { self.error = error.localizedDescription }
    }
}

struct MCPCertificateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AppMCPProfile
    let manager: AppMCPManager
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exchange Certificates").font(.title2.weight(.semibold))
            Text(profile.name + " · " + profile.server).foregroundStyle(.secondary)
            ScrollView { MCPCertificateSettingsView(profile: $profile).frame(maxWidth: .infinity, alignment: .leading) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save & Verify") {
                    do {
                        // An unchanged legacy file remains supported; Connect validates its contents.
                        if profile.certificateBundle.isEmpty {
                            try manager.setCertificates(profile.selectedCertificates, for: profile.id)
                        }
                        manager.connect(profile.id); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

enum MCPCertificateFilter: String, CaseIterable, Identifiable {
    case all = "All certificates", matching = "For this server", selfIssued = "Self-signed / self-issued", authorities = "CA certificates"
    var id: String { rawValue }
}

struct MCPKeychainCertificatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let host: String
    let selected: (AppMCPCertificateSelection) -> Void
    @State private var certificates: [AppMCPCertificate]?
    @State private var selectedIDs = Set<String>()
    @State private var search = ""
    @State private var filter = MCPCertificateFilter.all
    @State private var error: String?
    @State private var lookupError: String?
    @State private var suggestion: AppMCPCertificateSuggestion?
    @State private var finding: Task<Void, Never>?
    @State private var generation = UUID()

    init(host: String = "", certificates: [AppMCPCertificate]? = nil,
         suggestion: AppMCPCertificateSuggestion? = nil,
         selected: @escaping (AppMCPCertificateSelection) -> Void) {
        self.host = host
        _certificates = State(initialValue: certificates)
        _suggestion = State(initialValue: suggestion)
        self.selected = selected
    }

    private var available: [AppMCPCertificate] {
        var seen = Set<String>()
        return ((certificates ?? []) + (suggestion?.suggestedChain ?? [])).filter { seen.insert($0.id).inserted }
    }
    private var matchingIDs: Set<String> {
        (suggestion?.matchingIDs ?? []).union(suggestion?.suggestedChain.map(\.id) ?? [])
    }
    private var chosen: [AppMCPCertificate] { available.filter { selectedIDs.contains($0.id) } }
    private var matches: [AppMCPCertificate] {
        available.filter { certificate in
            let included: Bool = switch filter {
            case .all: true
            case .matching: matchingIDs.contains(certificate.id)
            case .selfIssued: certificate.isSelfIssued
            case .authorities: certificate.isCertificateAuthority
            }
            return included && (search.isEmpty ||
                [certificate.name, certificate.issuer, certificate.fingerprint,
                 certificate.fingerprint.replacingOccurrences(of: ":", with: "")]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted {
            if matchingIDs.contains($0.id) != matchingIDs.contains($1.id) { return matchingIDs.contains($0.id) }
            if ($0.validityIssue == nil) != ($1.validityIssue == nil) { return $0.validityIssue == nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Exchange Certificates").font(.title2.weight(.semibold))
            Text("All public certificates are shown, including self-signed certificates. Find a matching chain for your Exchange server to narrow the list.")
                .foregroundStyle(.secondary)
            serverLookup
            HStack {
                TextField("Search name, issuer or SHA-256", text: $search).textFieldStyle(.roundedBorder)
                Picker("Show", selection: $filter) {
                    ForEach(MCPCertificateFilter.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 210)
            }
            if let error {
                ContentUnavailableView("Could not read Keychain", systemImage: "exclamationmark.shield", description: Text(error))
            } else if certificates == nil {
                ProgressView("Reading public certificates…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                ContentUnavailableView("No matching certificates", systemImage: "doc.text.magnifyingglass",
                    description: Text(filter == .matching && suggestion == nil ? "Choose Find for Server first, or switch to All certificates." : "Try another filter or choose a certificate file supplied by IT."))
            } else {
                GeometryReader { _ in
                List(matches) { certificate in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("Select \(certificate.name)", isOn: Binding(get: { selectedIDs.contains(certificate.id) }, set: { on in
                            if on { selectedIDs.insert(certificate.id) } else { selectedIDs.remove(certificate.id) }
                        })).labelsHidden().toggleStyle(.checkbox).disabled(certificate.validityIssue != nil)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(certificate.name).fontWeight(.medium)
                                if matchingIDs.contains(certificate.id) {
                                    Label("Matches server", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(certificate.kindDescription).font(.caption).foregroundStyle(.secondary)
                            Text("Issuer: \(certificate.issuer) · Expires \(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let issue = certificate.validityIssue { Text(issue).font(.caption).foregroundStyle(.red) }
                            DisclosureGroup("SHA-256 fingerprint") {
                                Text(certificate.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                            }.font(.caption)
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
                }
            }
            Text("\(matches.count) shown · \(available.count) total. Selection trusts certificates for this Exchange connection only; TLS checks and Keychain settings stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(chosen.count) selected").foregroundStyle(.secondary)
                Button("Use Selected Certificates") {
                    selected(.init(certificates: chosen.map(\.der), source: "Certificate picker")); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(finding != nil || chosen.isEmpty || chosen.contains { $0.validityIssue != nil })
            }
        }.padding(24).frame(width: 780, height: 750)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { cancelLookup() }
        .onChange(of: host) {
            cancelLookup(); suggestion = nil; lookupError = nil; selectedIDs = []; filter = .all
        }
        .task {
            guard certificates == nil else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try AppMCPCertificates.inKeychain() }.value
                try Task.checkCancellation()
                certificates = result
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private var serverLookup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(host.isEmpty ? "Set the Exchange hostname first" : host).fontWeight(.medium)
                    Text("Reads TLS certificates from this server on port 443. No sign-in or mail is sent. Matching is local.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if finding != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel Search") { cancelLookup() }
                } else {
                    Button("Find for Server", systemImage: "sparkle.magnifyingglass") { findForServer() }
                        .disabled(certificates == nil || (try? AppMCPServerCertificates.normalizedHost(host)) == nil)
                }
            }
            if let lookupError { Text(lookupError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let suggestion {
                Text(suggestion.explanation).font(.callout)
                DisclosureGroup("Server certificate: \(suggestion.serverCertificate.name)") {
                    Text(suggestion.serverCertificate.kindDescription).font(.caption)
                    Text("Issuer: \(suggestion.serverCertificate.issuer)").font(.caption)
                    Text(suggestion.serverCertificate.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                }.font(.caption)
                if !suggestion.suggestedChain.isEmpty {
                    Button("Select Suggested Chain (\(suggestion.suggestedChain.count))") {
                        selectedIDs = Set(suggestion.suggestedChain.map(\.id)); filter = .matching; search = ""
                    }
                }
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
    }

    private func cancelLookup() {
        generation = UUID(); finding?.cancel(); finding = nil
    }
    private func findForServer() {
        cancelLookup(); lookupError = nil; suggestion = nil
        let current = generation
        let candidates = certificates ?? []
        finding = Task {
            do {
                let result = try await AppMCPServerCertificates.find(host: host, candidates: candidates)
                try Task.checkCancellation()
                guard current == generation else { return }
                suggestion = result
                if !result.matchingIDs.isEmpty { filter = .matching; search = "" }
            } catch is CancellationError {} catch {
                if current == generation { lookupError = error.localizedDescription }
            }
            if current == generation { finding = nil }
        }
    }
}
