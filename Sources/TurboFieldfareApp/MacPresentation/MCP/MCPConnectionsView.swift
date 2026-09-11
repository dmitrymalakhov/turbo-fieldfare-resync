import AppKit
import SwiftUI
import TurboFieldfareAppCore

public struct MCPConnectionsView: View {
    @Bindable private var manager: AppMCPManager
    private let useMail: @MainActor (AppMCPMailSnapshot) -> Void
    @State private var selection: UUID?
    @State private var addingConnection = false
    @State private var editing: AppMCPProfile?
    @State private var editingCertificates: AppMCPProfile?
    @State private var testing: AppMCPProfile?
    @State private var composing: AppMCPProfile?
    @State private var removing: AppMCPProfile?
    @State private var period = "today"
    @State private var folder = "Inbox"
    @State private var snapshot: AppMCPMailSnapshot?
    @State private var reading: Task<Void, Never>?
    @State private var readGeneration = UUID()
    @State private var readError: String?
    @State private var choosingMail: AppMCPMailReviewRequest?
    @State private var editingMailContacts: AppMCPProfile?

    public init(manager: AppMCPManager, initialSelection: UUID? = nil,
                useMail: @escaping @MainActor (AppMCPMailSnapshot) -> Void = { _ in }) {
        self.manager = manager; self.useMail = useMail
        _selection = State(initialValue: initialSelection)
    }
    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            connectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(TurboFieldfareMacTheme.accentColor)
        .onChange(of: selection) { stopReading(); snapshot = nil; readError = nil }
        .onChange(of: period) { snapshot = nil; readError = nil }
        .onChange(of: folder) { snapshot = nil; readError = nil }
        .onDisappear { stopReading() }
        .sheet(item: $editing) { profile in
            MCPProfileEditor(profile: profile, manager: manager, saved: { selection = $0 })
        }
        .sheet(item: $choosingMail) { request in
            MCPMailSelectionView(manager: manager, request: request, confirm: { ids in
                choosingMail = nil
                let generation = UUID(); readGeneration = generation
                reading = Task { @MainActor in
                    do {
                        let result = try await manager.readSelectedMail(request.preview, selection: ids)
                        try Task.checkCancellation()
                        if selection == request.preview.profileID && readGeneration == generation { snapshot = result }
                    } catch is CancellationError { }
                    catch { if readGeneration == generation { readError = error.localizedDescription } }
                    if readGeneration == generation { reading = nil }
                }
            }, cancel: { choosingMail = nil })
        }
        .sheet(item: $editingMailContacts) { profile in
            MCPMailContactsView(manager: manager, profileID: profile.id, contacts: profile.mailContacts ?? .init())
        }
        .sheet(item: $editingCertificates) { profile in
            MCPCertificateEditor(profile: profile, manager: manager)
        }
        .sheet(item: $testing) { profile in
            MCPConnectionTestView(manager: manager, profileID: profile.id)
        }
        .sheet(item: $composing) { profile in
            SMTPComposeView(profile: profile, manager: manager)
        }
        .sheet(isPresented: $addingConnection) {
            MCPNewConnectionView(manager: manager) { saved in selection = saved }
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "Remove MCP integration?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove Integration", role: .destructive) {
                    guard let removing else { return }
                    do { try manager.remove(removing.id) }
                    catch { manager.error = error.localizedDescription }
                    if !manager.profiles.contains(where: { $0.id == removing.id }) {
                        stopReading()
                        selection = nil
                    }
                    self.removing = nil
                }
            } message: {
                Text("This stops its MCP process and removes it from chat, saved settings and Keychain credentials. This cannot be undone.")
            }
        .alert("Connections", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("OK") { manager.error = nil }
        } message: { Text(manager.error ?? "") }
    }

    @ViewBuilder
    private var connectionContent: some View {
        if let profile = manager.profiles.first(where: { $0.id == selection }) {
            detail(profile)
        } else {
            MCPOverviewView(manager: manager, openConnection: { selection = $0 },
                            addConnection: { addingConnection = true },
                            removeConnection: { removing = $0 })
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MCP").font(.title3.weight(.semibold))
                Spacer()
                Button { addingConnection = true } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("Add MCP server")
                    .accessibilityLabel("Add MCP server")
            }
            .padding(18)
            Button { selection = nil } label: {
                Label("Overview", systemImage: "square.grid.2x2")
                    .font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(selection == nil ? TurboFieldfareMacTheme.accentColor.opacity(0.12) : Color.clear,
                                in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 24)
            HStack {
                Text("SERVERS").font(.caption2.weight(.semibold))
                Spacer()
                Text("\(manager.profiles.count)").font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
            List(selection: $selection) {
                ForEach(manager.profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.kind.symbol)
                            .font(.title3).frame(width: 28).foregroundStyle(TurboFieldfareMacTheme.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(manager.status(profile.id).title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if manager.status(profile.id) == .connected {
                            Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Connected")
                        }
                    }
                    .padding(.vertical, 6)
                    .contextMenu {
                        Button("Remove Integration…", role: .destructive) { removing = profile }
                    }
                    .tag(profile.id)
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            Label("Credentials in Keychain", systemImage: "key.horizontal")
                .font(.caption).foregroundStyle(.secondary).padding(18)
        }
        .background(TurboFieldfareMacTheme.sidebarBackgroundColor)
    }

    private func detail(_ profile: AppMCPProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: profile.kind.symbol).font(.system(size: 28))
                        .foregroundStyle(TurboFieldfareMacTheme.accentColor)
                        .frame(width: 56, height: 56).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name).font(.title.weight(.semibold))
                        Text(profile.kind.isMail ? profile.email : profile.kind.title).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { removing = profile } label: {
                        Label("Remove Integration…", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityLabel("Remove MCP integration \(profile.name)")
                    Menu {
                        Button("Edit Connection…") { editing = profile }
                        Button("Forget Credentials") {
                            do { try manager.forgetCredentials(profile.id) }
                            catch { manager.error = error.localizedDescription }
                        }
                        Divider()
                        Button("Remove Integration…", role: .destructive) { removing = profile }
                    } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize().help("Connection options")
                }

                card {
                    HStack {
                        if manager.status(profile.id).isBusy { ProgressView().controlSize(.small) }
                        else { Image(systemName: manager.status(profile.id) == .connected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(manager.status(profile.id) == .connected ? Color.green : Color.secondary) }
                        Text(manager.status(profile.id).title).fontWeight(.medium)
                        Spacer()
                        Button("Test Data…") { testing = profile }
                            .help("Call an enabled tool and inspect its response")
                        if manager.status(profile.id).isBusy || manager.status(profile.id) == .connected {
                            Button(manager.status(profile.id).isBusy ? "Cancel" : "Disconnect") { manager.disconnect(profile.id) }
                        } else {
                            Button("Connect & Verify") { manager.connect(profile.id) }
                                .buttonStyle(.borderedProminent)
                                .disabled(profile.kind != .smtp && profile.executable.isEmpty)
                        }
                    }
                    if case .failed(let message) = manager.status(profile.id) {
                        Text(message.components(separatedBy: "\n").first ?? message)
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        if profile.kind.isMail, message.localizedCaseInsensitiveContains("certificate") {
                            Button("Choose Certificates…") { editingCertificates = profile }
                        }
                    }
                    if profile.kind == .exchange, let python = manager.pythonInfo[profile.id] {
                        Label("Last Python check: \(python.version) · passed", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if let checked = manager.lastChecked[profile.id] {
                        Text("Last verified \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let report = manager.diagnostics[profile.id], !report.steps.isEmpty {
                    card { MCPDiagnosticsView(report: report) }
                }

                if profile.kind.isMail {
                    card {
                        sectionTitle("Certificates", symbol: "checkmark.shield")
                        Text(profile.selectedCertificates.map { "\($0.certificates.count) certificate(s) · \($0.source)" }
                             ?? (profile.certificateBundle.isEmpty ? "Python default CA certificates" : "Custom CA bundle"))
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Choose Certificates…") { editingCertificates = profile }
                            .disabled(manager.status(profile.id).isBusy)
                    }
                    if profile.kind == .exchange { card { MCPPythonSetupView(manager: manager, profile: profile).id(profile.id) } }
                }

                card {
                    sectionTitle("Connection & Authentication", symbol: "key.horizontal")
                    if profile.kind == .smtp {
                        LabeledContent("Server", value: "\(profile.server):\(profile.effectiveSMTPPort)")
                        LabeledContent("Security", value: profile.effectiveSMTPSecurity)
                        LabeledContent("Username", value: profile.username)
                        LabeledContent("From", value: profile.email)
                    } else if profile.kind == .exchange {
                        LabeledContent("Server", value: profile.server)
                        LabeledContent("Username", value: profile.username)
                        LabeledContent("Method", value: profile.authType)
                        LabeledContent("Time zone", value: profile.timezone)
                    } else {
                        LabeledContent("Executable", value: profile.executable)
                        LabeledContent("Environment variables", value: "\(profile.environmentKeys.count) saved in Keychain")
                    }
                    Button("Edit Connection & Credentials…") { editing = profile }
                }

                toolsCard(profile)
                if profile.kind == .exchange { mailCard(profile) }
                if profile.kind == .smtp {
                    card {
                        sectionTitle("Send Mail", symbol: "paperplane")
                        Text("Compose a text email and review it before sending. SMTP does not read your inbox.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Compose Email…") { composing = profile }
                            .disabled(manager.status(profile.id) != .connected)
                    }
                }
            }
            .padding(28).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private func toolsCard(_ profile: AppMCPProfile) -> some View {
        card {
            sectionTitle("Tools", symbol: "switch.2")
            if let tools = manager.tools[profile.id], !tools.isEmpty {
                ForEach(tools) { tool in
                    Toggle(isOn: Binding(get: { manager.profiles.first(where: { $0.id == profile.id })?.enabledTools.contains(tool.name) == true },
                                         set: { enabled in
                        do { try manager.setToolEnabled(tool.name, enabled: enabled, id: profile.id) }
                        catch { manager.error = error.localizedDescription }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name).font(.callout.monospaced())
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(tool.description)
                        }
                    }.toggleStyle(.switch)
                }
            } else { Text("Connect to discover available tools.").font(.callout).foregroundStyle(.secondary) }
            if profile.kind == .exchange {
                Label("Read-only mail and calendar", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func mailCard(_ profile: AppMCPProfile) -> some View {
        card {
            sectionTitle("Mail for your conversation", symbol: "tray.full")
            Text("You can also request mail for today, yesterday or this week directly in chat.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Контакты и группы…") { editingMailContacts = manager.profiles.first { $0.id == profile.id } }
            Picker("Period", selection: $period) {
                Text("Today").tag("today"); Text("Yesterday").tag("yesterday"); Text("This Week").tag("this_week")
            }.pickerStyle(.segmented)
                .disabled(reading != nil)
            Text(period == "this_week" ? "From Monday at midnight until now · \(profile.timezone)" :
                    "Calendar day in \(profile.timezone)").font(.caption).foregroundStyle(.secondary)
            LabeledContent("Folder") { TextField("Inbox", text: $folder).textFieldStyle(.roundedBorder).frame(maxWidth: 220) }
                .disabled(reading != nil)
            Text("Сначала заголовки и отправители. Тексты писем загружаются после выбора.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if reading != nil {
                    ProgressView().controlSize(.small)
                    Text("Загрузка выбранной почты…").font(.callout)
                    Spacer()
                    Button("Cancel") { stopReading() }
                } else {
                    Button("Выбрать письма…") {
                        snapshot = nil; readError = nil
                        let id = profile.id, chosenPeriod = period, chosenFolder = folder
                        let generation = UUID(); readGeneration = generation
                        reading = Task { @MainActor in
                            do {
                                let preview = try await manager.previewMail(id, period: chosenPeriod, folder: chosenFolder)
                                try Task.checkCancellation()
                                if selection == id && readGeneration == generation {
                                    choosingMail = .init(profileName: profile.name, prompt: "", preview: preview,
                                        contacts: manager.profiles.first(where: { $0.id == id })?.mailContacts ?? .init())
                                }
                            } catch is CancellationError { }
                            catch { if selection == id && readGeneration == generation { readError = error.localizedDescription } }
                            if selection == id && readGeneration == generation { reading = nil }
                        }
                    }
                    .disabled(manager.status(profile.id) != .connected || !profile.enabledTools.isSuperset(of: ["list_messages", "get_message"]))
                }
                if let snapshot, reading == nil {
                    Spacer()
                    Text("\(snapshot.count) messages").font(.callout).foregroundStyle(.secondary)
                    if let count = snapshot.bodyCharacterCount {
                        Text("\(count.formatted()) символов текста").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Add to Chat") { useMail(snapshot) }.buttonStyle(.borderedProminent).disabled(snapshot.count == 0)
                }
            }
            if let readError { Text(readError).font(.callout).foregroundStyle(.red) }
            if let snapshot {
                if !snapshot.complete { Label("Import is incomplete. Narrow the period or folder.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange) }
                DisclosureGroup("Preview · \(snapshot.text.count.formatted()) characters") {
                    ScrollView {
                        Text(String(snapshot.text.prefix(20_000))).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                    if snapshot.text.count > 20_000 { Text("Preview shows the first 20,000 characters.").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Mail is attached as reference text. Large imports may be shortened to fit the chat context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.headline).padding(.bottom, 2)
    }
    private func stopReading() {
        readGeneration = UUID(); reading?.cancel(); reading = nil
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4), lineWidth: 0.5))
    }
}

@MainActor
private func chooseFile(directory: Bool = false, selected: (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { selected(url.path) }
}

struct MCPProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AppMCPProfile
    let manager: AppMCPManager
    let saved: (UUID) -> Void
    var goBack: (() -> Void)?
    @State private var credentials = AppMCPCredentials()
    @State private var argumentLines = ""
    @State private var variables: [EnvironmentVariable] = []
    @State private var error: String?
    @State private var loadedSecrets = false
    private struct EnvironmentVariable: Identifiable {
        var id = UUID(); var name = ""; var value = ""
    }
    init(profile: AppMCPProfile, manager: AppMCPManager, goBack: (() -> Void)? = nil,
         saved: @escaping (UUID) -> Void = { _ in }) {
        _profile = State(initialValue: profile); self.manager = manager; self.goBack = goBack; self.saved = saved
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.kind == .smtp ? "Connect SMTP" : (profile.kind == .exchange ? "Connect Exchange" : "Local MCP Server")).font(.title2.weight(.semibold))
                    Text(profile.kind == .smtp ? "Send mail through your SMTP server." : (profile.kind == .exchange ? "Read mail with your corporate account." : "Run a local MCP executable with its own credentials."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    if profile.kind.isMail {
                        TextField(profile.kind == .smtp ? "SMTP host" : "Exchange host", text: $profile.server, prompt: Text("mail.company.com"))
                        TextField(profile.kind == .smtp ? "From address" : "Mailbox", text: $profile.email, prompt: Text("you@company.com"))
                        if profile.kind == .smtp {
                            TextField("Port", value: Binding(get: { profile.effectiveSMTPPort }, set: { profile.smtpPort = $0 }), format: .number.grouping(.never))
                            Picker("Security", selection: Binding(get: { profile.effectiveSMTPSecurity }, set: {
                                profile.smtpSecurity = $0
                                if [465, 587].contains(profile.effectiveSMTPPort) { profile.smtpPort = $0 == "TLS" ? 465 : 587 }
                            })) { Text("STARTTLS (usually 587)").tag("STARTTLS"); Text("TLS (usually 465)").tag("TLS") }
                            HStack {
                                TextField("Python 3 executable", text: Binding(get: { profile.pythonExecutable ?? "" }, set: { profile.pythonExecutable = $0 }))
                                Button("Choose…") { chooseFile { profile.pythonExecutable = $0 } }
                            }
                            Text("Uses Python 3.9 or newer. No connector packages need to be installed.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack { TextField("Executable", text: $profile.executable)
                            Button("Choose…") { chooseFile { profile.executable = $0 } } }
                        VStack(alignment: .leading) {
                            Text("Arguments · one per line").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $argumentLines).font(.body.monospaced()).frame(height: 65)
                        }
                        HStack { TextField("Working directory", text: $profile.workingDirectory)
                            Button("Choose…") { chooseFile(directory: true) { profile.workingDirectory = $0 } } }
                    }
                }
                Section("Authentication") {
                    if profile.kind.isMail {
                        TextField("Username", text: $profile.username, prompt: Text("DOMAIN\\username"))
                        SecureField("Password", text: $credentials.password)
                        if profile.kind == .exchange {
                            Picker("Method", selection: $profile.authType) { Text("NTLM").tag("NTLM"); Text("Basic over TLS").tag("BASIC") }
                        }
                    } else {
                        ForEach($variables) { $variable in
                            HStack {
                                TextField("Variable name", text: $variable.name).font(.body.monospaced())
                                SecureField("Value", text: $variable.value)
                                Button { variables.removeAll { $0.id == variable.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove variable")
                            }
                        }
                        Button("Add Environment Variable") { variables.append(EnvironmentVariable()) }
                    }
                    Label("Secrets are saved in this Mac’s Keychain.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if profile.kind.isMail {
                    Section("Certificates") { MCPCertificateSettingsView(profile: $profile) }
                }
                if profile.kind == .exchange {
                    Section("Mail preferences") {
                        TextField("Time zone", text: $profile.timezone)
                        Text("Today, yesterday and week boundaries use this time zone. Weeks start on Monday.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        DisclosureGroup("Advanced") {
                            HStack { TextField("Existing MCP executable (optional)", text: $profile.executable)
                                Button("Choose…") { chooseFile { profile.executable = $0 } } }
                            Text("Leave the executable empty to install the included connector after saving.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("This field is for exchange-mcp, not Python. Choose Python in the connector setup after saving.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            HStack {
                if let goBack { Button("Back", action: goBack) }
                else { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Spacer()
                if goBack != nil { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button("Save Connection") {
                    do {
                        profile.arguments = argumentLines.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                        profile.environmentKeys = variables.map(\.name)
                        guard Set(profile.environmentKeys).count == variables.count else { throw AppMCPError.configuration("Use a unique name for each environment variable.") }
                        credentials.environment = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0.value) })
                        try manager.save(profile, credentials: credentials)
                        saved(profile.id); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!loadedSecrets)
            }.padding(20)
        }
        .frame(width: 610, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            argumentLines = profile.arguments.joined(separator: "\n")
            do {
                credentials = try manager.credentials(profile.id)
                variables = profile.environmentKeys.map { EnvironmentVariable(name: $0, value: credentials.environment[$0] ?? "") }
                loadedSecrets = true
            } catch { self.error = error.localizedDescription }
        }
    }
}
