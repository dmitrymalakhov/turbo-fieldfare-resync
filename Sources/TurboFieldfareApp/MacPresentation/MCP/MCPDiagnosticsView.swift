import AppKit
import SwiftUI
import TurboFieldfareAppCore

struct MCPPythonSetupView: View {
    let manager: AppMCPManager
    let profile: AppMCPProfile
    @State private var python: String
    @State private var discovery: AppMCPPythonDiscovery
    @State private var manualPath = false
    @State private var userSelected: Bool

    init(manager: AppMCPManager, profile: AppMCPProfile, discovery: AppMCPPythonDiscovery = AppMCPPythonDiscovery()) {
        self.manager = manager; self.profile = profile
        _python = State(initialValue: profile.pythonExecutable ?? AppMCPExchangeInstaller.suggestedPython)
        _discovery = State(initialValue: discovery)
        _userSelected = State(initialValue: profile.pythonExecutable != nil)
    }
    private var verifiedPython: AppMCPPythonInfo? {
        if let installed = discovery.installations.first(where: { $0.path == python && $0.isCompatible }) { return installed.info }
        return AppMCPExchangeInstaller.normalizedPythonPath(python) == profile.pythonExecutable ? manager.pythonInfo[profile.id] : nil
    }
    private var compatible: [AppMCPPythonInstallation] { discovery.installations.filter(\.isCompatible) }
    private var pythonBinding: Binding<String> {
        Binding(get: { python }, set: { python = $0; userSelected = true })
    }
    private var disabled: Bool {
        manager.status(profile.id).isBusy || manager.status(profile.id) == .connected
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Python & Exchange connector", systemImage: "shippingbox").font(.headline)
            Text("Find Python on this Mac, select an installation, then install the connector's dependencies.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { discovery.search() } label: {
                    Label(discovery.hasSearched ? "Find Python Again" : "Find Python", systemImage: "magnifyingglass")
                }.disabled(disabled || discovery.isSearching)
                if discovery.isSearching {
                    ProgressView().controlSize(.small)
                    Text(discovery.progress).font(.caption).foregroundStyle(.secondary)
                    Button("Cancel Search") { discovery.cancel() }
                }
            }
            if !compatible.isEmpty {
                Picker("Installed Python", selection: pythonBinding) {
                    if !compatible.contains(where: { $0.path == python }) {
                        Text(python.isEmpty ? "Select Python" : "Current selection (manual)").tag(python)
                    }
                    ForEach(compatible) { installation in
                        Text(installation.title).tag(installation.path)
                    }
                }.disabled(disabled || discovery.isSearching)
                Text(python).font(.caption.monospaced()).textSelection(.enabled)
            } else if discovery.hasSearched, !discovery.isSearching {
                Label("No compatible Python found in the usual locations", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                Text("Python 3.10+ is required. If it is installed elsewhere, choose its file below and check it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = discovery.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            let unavailable = discovery.installations.filter { !$0.isCompatible }
            if !unavailable.isEmpty {
                DisclosureGroup("Unavailable installations (\(unavailable.count))") {
                    ForEach(unavailable) { installation in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(installation.title).font(.caption.weight(.medium))
                            Text(installation.path).font(.caption.monospaced())
                            Text(installation.issue ?? "Cannot use this Python").font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled).padding(.vertical, 4)
                    }
                }
            }
            DisclosureGroup("Choose a file or enter a path manually", isExpanded: $manualPath) {
                HStack {
                    TextField("Python 3.10+ executable", text: pythonBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Python executable path")
                    Button("Choose File…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { pythonBinding.wrappedValue = url.path }
                    }
                }.disabled(disabled || discovery.isSearching)
            }
            if let info = verifiedPython {
                Label("Python \(info.version) verified", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(info.executable).font(.caption.monospaced()).textSelection(.enabled)
                Text("Runs correctly · venv and ensurepip available")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Find Python or check a manually selected file to verify it", systemImage: "circle.dashed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check Python") { manager.checkPython(profile.id, python: python) }
                Button(profile.executable.isEmpty ? "Install Connector" : "Install / Repair Connector") {
                    manager.installExchange(profile.id, python: python)
                }
            }.disabled(python.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled || discovery.isSearching)
            Text(manager.status(profile.id) == .connected
                 ? "Disconnect before checking or changing the connector environment."
                 : "Finding and checking Python works locally without downloads. Installation downloads the connector's Python packages.")
                .font(.caption).foregroundStyle(.secondary)
            if !profile.executable.isEmpty {
                Text("Repair rebuilds the shared Exchange environment and disconnects connections that use it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !profile.executable.isEmpty {
                LabeledContent("Connector executable") {
                    Text(profile.executable).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .onChange(of: discovery.isSearching) {
            if !discovery.isSearching, !userSelected, let preferred = compatible.first {
                python = preferred.path
            }
        }
        .onDisappear { discovery.cancel() }
    }
}

public struct MCPDiagnosticsView: View {
    @Bindable private var report: AppMCPDiagnostics
    public init(report: AppMCPDiagnostics) { self.report = report }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Connection diagnostics", systemImage: "list.bullet.clipboard").font(.headline)
                Spacer()
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                }
            }
            Text("Last attempt · \(report.startedAt.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(report.steps) { step in
                MCPDiagnosticStepView(step: step)
            }
            Text("Diagnostics stay in this app session. Saved credentials are masked; nothing is sent automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MCPDiagnosticStepView: View {
    let step: AppMCPDiagnosticStep
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch step.state {
                case .running: ProgressView().controlSize(.small)
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
                Text(step.title).fontWeight(.medium)
                Spacer()
                if step.state == .failed { Text("Failed").foregroundStyle(.red).font(.caption) }
                if step.state == .cancelled { Text("Cancelled").foregroundStyle(.secondary).font(.caption) }
            }
            if !step.detail.isEmpty {
                DisclosureGroup(step.state == .failed ? "Error details" : "Details", isExpanded: $expanded) {
                    ScrollView {
                        Text(step.detail).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: min(180, max(44, CGFloat(step.detail.count / 85 + step.detail.components(separatedBy: "\n").count) * 16)))
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                }.padding(.leading, 24)
            }
        }
        .onChange(of: step.state, initial: true) { expanded = step.state == .failed }
    }
}
