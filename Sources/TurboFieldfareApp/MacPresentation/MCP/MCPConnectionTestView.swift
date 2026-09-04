import AppKit
import SwiftUI
import TurboFieldfareAppCore

struct MCPConnectionTestView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var manager: AppMCPManager
    let profileID: UUID
    @State private var runner: AppMCPConnectionTest
    @State private var selectedTool = ""
    @State private var argumentsJSON = "{}"
    @State private var rawResponse = false
    @State private var showSchema = false
    @State private var showParameters = true

    init(manager: AppMCPManager, profileID: UUID, runner: AppMCPConnectionTest = .init()) {
        self.manager = manager; self.profileID = profileID
        _runner = State(initialValue: runner)
        _showParameters = State(initialValue: runner.result == nil)
        let profile = manager.profiles.first { $0.id == profileID }
        let tools = manager.tools[profileID, default: []]
        let enabled = tools.filter { profile?.enabledTools.contains($0.name) == true }
        let tool = (profile?.kind == .exchange ? enabled.first { $0.name == "list_messages" } : nil)
            ?? enabled.first(where: \.readOnly) ?? enabled.first ?? tools.first
        _selectedTool = State(initialValue: tool?.name ?? "")
        _argumentsJSON = State(initialValue: tool.map { AppMCPTestInput.template(tool: $0, kind: profile?.kind ?? .stdio) } ?? "{}")
    }

    private var profile: AppMCPProfile? { manager.profiles.first { $0.id == profileID } }
    private var tools: [AppMCPTool] { manager.tools[profileID, default: []] }
    private var tool: AppMCPTool? { tools.first { $0.name == selectedTool } }
    private var enabled: Bool { profile?.enabledTools.contains(selectedTool) == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(TurboFieldfareMacTheme.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test MCP Connection").font(.title2.weight(.semibold))
                    Text(profile?.name ?? "Connection removed").foregroundStyle(.secondary)
                }
                Spacer()
                if profile?.kind == .exchange {
                    Label("Read-only", systemImage: "checkmark.shield").font(.callout).foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionStatus
                    if tools.isEmpty {
                        ContentUnavailableView("No tools available", systemImage: "puzzlepiece.extension",
                            description: Text("Connect to discover the server’s tools. Then choose a tool to request sample data."))
                    } else {
                        requestEditor
                        responseViewer
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Text("Results stay in memory until you clear or close this window.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
        }
        .frame(width: 800, height: 800)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(TurboFieldfareMacTheme.accentColor)
        .onChange(of: selectedTool) { resetInput() }
        .onChange(of: tools) { selectAvailableTool() }
        .onChange(of: profile) { runner.clear() }
        .onChange(of: runner.result?.receivedAt) { if runner.result != nil { showParameters = false } }
        .onDisappear { runner.clear() }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if manager.status(profileID).isBusy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: manager.status(profileID) == .connected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(manager.status(profileID) == .connected ? Color.green : Color.secondary)
                }
                Text(manager.status(profileID).title).fontWeight(.medium)
                Spacer()
                if manager.status(profileID).isBusy {
                    Button("Cancel Connection") { manager.disconnect(profileID) }
                } else if manager.status(profileID) != .connected {
                    Button("Connect & Verify") { manager.connect(profileID) }
                        .disabled(profile?.executable.isEmpty != false)
                }
            }
            if case .failed(let message) = manager.status(profileID) {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if profile?.executable.isEmpty == true {
                Text("Set up the connector in this server’s settings first.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Run a tool to check the data returned by this server.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var requestEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tool", selection: $selectedTool) {
                ForEach(tools) { item in
                    Text(item.name + (profile?.enabledTools.contains(item.name) == true ? "" : " (disabled)"))
                        .tag(item.name)
                }
            }.disabled(runner.isRunning)
            if let tool {
                Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).help(tool.description).textSelection(.enabled)
                if !enabled {
                    Label("Enable this tool in the server’s Tools section to test it.", systemImage: "switch.2")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if profile?.kind != .exchange {
                    Text(tool.readOnly ? "Server describes this tool as read-only." : "This tool may change data. Review its description and parameters before running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if profile?.kind == .exchange && tool.name == "list_messages" {
                    HStack {
                        Text("Sample mail").font(.callout.weight(.medium))
                        ForEach([("Today", "today"), ("Yesterday", "yesterday"), ("This Week", "this_week")], id: \.1) { title, period in
                            Button(title) {
                                runner.clear()
                                argumentsJSON = AppMCPTestInput.template(tool: tool, kind: .exchange, period: period)
                            }
                        }
                        Spacer()
                    }.disabled(runner.isRunning)
                    Text("Presets: up to 3 messages, without bodies · \(profile?.timezone ?? ""). Run Test to fetch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Parameters · JSON").font(.callout.weight(.medium))
                    Spacer()
                    Button("Reset Parameters") { resetInput() }.buttonStyle(.link).disabled(runner.isRunning)
                }
                DisclosureGroup("Edit parameters", isExpanded: $showParameters) {
                    TextEditor(text: $argumentsJSON).font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(8).frame(height: 135)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)))
                    .disabled(runner.isRunning).accessibilityLabel("Tool parameters as JSON")
                    DisclosureGroup("Parameter schema", isExpanded: $showSchema) {
                        code(AppMCPTestInput.json(tool.schema), height: 140)
                        Text("Fill required values before running. The server validates the full parameter schema.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.caption)
                }.font(.callout)
                HStack(spacing: 12) {
                    Button {
                        rawResponse = false
                        runner.start(manager: manager, id: profileID, tool: tool, argumentsJSON: argumentsJSON)
                    } label: { Label("Run Test", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(runner.isRunning || !enabled || manager.status(profileID) != .connected)
                    if runner.isRunning {
                        ProgressView().controlSize(.small)
                        Text("Waiting for response…").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { runner.cancel() }
                    } else {
                        Text("One request using the parameters above.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var responseViewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let error = runner.error {
                Label("Test did not complete", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
                Text(error).font(.callout).textSelection(.enabled)
            } else if let result = runner.result {
                HStack {
                    Label(result.isError ? "Tool error" : "Response received",
                          systemImage: result.isError ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(result.isError ? Color.red : Color.green)
                    Spacer()
                    Button("Copy JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.json, forType: .string)
                    }
                    Button("Clear") { runner.clear() }
                }
                Text(result.summary).font(.callout)
                Text("\(result.tool) · \(result.elapsed.formatted(.number.precision(.fractionLength(2)))) s · \(ByteCountFormatter.string(fromByteCount: Int64(result.byteCount), countStyle: .file)) · \(result.receivedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show full MCP envelope", isOn: $rawResponse).toggleStyle(.checkbox).font(.caption)
                let text = responseText(result)
                code(text, height: 210)
                if text.count > 50_000 {
                    Text("Preview shows the first 50,000 characters. Copy JSON includes the complete response.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Parameters used for this response") {
                    code(AppMCPTestInput.json(result.arguments), height: 100)
                }.font(.caption)
            } else if !runner.isRunning {
                Label("No test run yet", systemImage: "tray").font(.headline).foregroundStyle(.secondary)
                Text("The response will appear here after you run a test.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func responseText(_ result: AppMCPTestResult) -> String {
        if rawResponse { return result.json }
        if let value = result.response["structuredContent"] { return AppMCPTestInput.json(value) }
        if let content = result.response["content"]?.arrayValue, !content.isEmpty,
           content.allSatisfy({ $0["type"]?.stringValue == "text" }) {
            return content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        }
        return result.json
    }
    private func code(_ text: String, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                Text(String(text.prefix(50_000))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(minWidth: max(0, geometry.size.width - 24), minHeight: max(0, height - 24), alignment: .topLeading)
                    .padding(12)
            }
        }.frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.5)))
    }
    private func resetInput() {
        runner.clear()
        showParameters = true
        argumentsJSON = tool.map { AppMCPTestInput.template(tool: $0, kind: profile?.kind ?? .stdio) } ?? "{}"
    }
    private func selectAvailableTool() {
        runner.clear()
        if tool != nil { resetInput(); return }
        let available = tools.filter { profile?.enabledTools.contains($0.name) == true }
        selectedTool = (profile?.kind == .exchange ? available.first { $0.name == "list_messages" } : nil)?.name
            ?? available.first(where: \.readOnly)?.name ?? available.first?.name ?? tools.first?.name ?? ""
        resetInput()
    }
}
