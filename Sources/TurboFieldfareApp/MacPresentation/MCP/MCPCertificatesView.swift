import AppKit
import SwiftUI
import TurboFieldfareAppCore
import UniformTypeIdentifiers

struct MCPCertificateSettingsView: View {
    @Binding var profile: AppMCPProfile
    @State private var choosingKeychain = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection = profile.selectedCertificates {
                Label("\(selection.certificates.count) CA certificate(s) · \(selection.source)", systemImage: "checkmark.shield")
                    .fontWeight(.medium)
                if let certificates = try? AppMCPCertificates.inspect(selection) {
                    ForEach(certificates) { certificate in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(certificate.name).fontWeight(.medium)
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
            if profile.selectedCertificates != nil || !profile.certificateBundle.isEmpty {
                Button("Use Default Certificates") { select(nil) }.buttonStyle(.link)
            }
            Text("The selected CA certificates are trusted only for this Exchange connection. TLS checks stay enabled. Keychain trust settings are unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: $choosingKeychain) {
            MCPKeychainCertificatePicker { select($0) }
        }
    }

    private func select(_ selection: AppMCPCertificateSelection?) {
        profile.selectedCertificates = selection; profile.certificateBundle = ""; error = nil
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose corporate CA certificates"
        panel.message = "Choose a PEM bundle or a CER, CRT or DER certificate. Private keys and P12/PFX identities are not needed."
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

struct MCPKeychainCertificatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let selected: (AppMCPCertificateSelection) -> Void
    @State private var certificates: [AppMCPCertificate]?
    @State private var selectedIDs = Set<String>()
    @State private var search = ""
    @State private var showOtherCertificates = false
    @State private var error: String?

    init(certificates: [AppMCPCertificate]? = nil,
         selected: @escaping (AppMCPCertificateSelection) -> Void) {
        _certificates = State(initialValue: certificates); self.selected = selected
    }

    private var chosen: [AppMCPCertificate] {
        (certificates ?? []).filter { selectedIDs.contains($0.id) }
    }
    private var matches: [AppMCPCertificate] {
        (certificates ?? []).filter {
            (showOtherCertificates || $0.isCertificateAuthority) && (search.isEmpty ||
                [$0.name, $0.issuer, $0.fingerprint, $0.fingerprint.replacingOccurrences(of: ":", with: "")]
                    .contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Certificates from Keychain").font(.title2.weight(.semibold))
            Text("Select your corporate issuing CA. Public certificates from this Mac are listed locally; private keys are never read.")
                .foregroundStyle(.secondary)
            TextField("Search by name, issuer or SHA-256 fingerprint", text: $search)
                .textFieldStyle(.roundedBorder)
            Toggle("Show personal and server certificates", isOn: $showOtherCertificates).font(.caption)
            if let error {
                ContentUnavailableView("Could not read Keychain", systemImage: "exclamationmark.shield", description: Text(error))
            } else if certificates == nil {
                ProgressView("Reading public certificates…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                ContentUnavailableView("No matching certificates", systemImage: "doc.text.magnifyingglass",
                    description: Text("Try another name or choose a certificate file supplied by your IT team."))
            } else {
                List(matches) { certificate in
                    Toggle(isOn: Binding(get: { selectedIDs.contains(certificate.id) }, set: { on in
                        if on { selectedIDs.insert(certificate.id) } else { selectedIDs.remove(certificate.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(certificate.name).fontWeight(.medium)
                            Text("Issuer: \(certificate.issuer)").font(.caption).foregroundStyle(.secondary)
                            Text("Expires \(certificate.notAfter.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let issue = certificate.validityIssue { Text(issue).font(.caption).foregroundStyle(.red) }
                            DisclosureGroup("SHA-256 fingerprint") {
                                Text(certificate.fingerprint).font(.caption2.monospaced()).textSelection(.enabled)
                            }.font(.caption)
                        }.padding(.vertical, 6)
                    }.toggleStyle(.checkbox).disabled(certificate.validityIssue != nil)
                }.listStyle(.inset)
            }
            Text("Selection adds trust for this Exchange connection only. Installing a certificate in Keychain does not automatically make it a trusted CA in Python.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(chosen.count) selected").foregroundStyle(.secondary)
                Button("Use Selected Certificates") {
                    selected(.init(certificates: chosen.map(\.der), source: "Keychain")); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || chosen.contains { $0.validityIssue != nil })
            }
        }.padding(24).frame(width: 720, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            guard certificates == nil else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try AppMCPCertificates.inKeychain() }.value
                try Task.checkCancellation()
                certificates = result
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
