import AppKit
import SwiftUI
import TurboFieldfareAppCore

struct MCPOverviewView: View {
    @Bindable var manager: AppMCPManager
    let openConnection: (UUID) -> Void
    let addConnection: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MCP Connections").font(.title.weight(.semibold))
                        Text("Manage servers, credentials and tool access in one place.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    if !manager.profiles.isEmpty { addButton }
                }
                if manager.profiles.isEmpty { emptyState }
                else { connections }
            }
            .padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var addButton: some View {
        Button(action: addConnection) { Label("Add MCP Server", systemImage: "plus") }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }

    private var emptyState: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(TurboFieldfareMacTheme.accentColor)
                    .frame(width: 94, height: 94)
                    .background(TurboFieldfareMacTheme.accentColor.opacity(0.08), in: .rect(cornerRadius: 24))
                Text("Connect your tools and services").font(.title2.weight(.semibold))
                Text("Add an MCP server to configure its connection,\nmanage credentials and choose available tools.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                addButton.padding(.top, 4)
            }
            .frame(maxWidth: .infinity).padding(.top, 62).padding(.bottom, 12)
            HStack(alignment: .top, spacing: 12) {
                feature("Connect", symbol: "point.3.connected.trianglepath.dotted",
                        text: "Keep your servers and their connection status together.")
                feature("Authenticate", symbol: "key.horizontal",
                        text: "Set credentials for each server in macOS Keychain.")
                feature("Manage tools", symbol: "switch.2",
                        text: "Review the tools a server provides and control access.")
            }
            Text("Start with a local MCP server or a ready-to-configure preset.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center)
        }
    }

    private func feature(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(TurboFieldfareMacTheme.accentColor)
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).frame(minHeight: 112, alignment: .topLeading)
        .padding(16).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                statistic("Servers", value: manager.profiles.count, symbol: "server.rack")
                statistic("Connected", value: manager.profiles.filter { manager.status($0.id) == .connected }.count,
                          symbol: "checkmark.circle")
                statistic("Enabled tools", value: manager.profiles.reduce(0) { $0 + $1.enabledTools.count },
                          symbol: "switch.2")
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Your servers").font(.headline)
                ForEach(manager.profiles) { profile in serverRow(profile) }
            }
            Label("Select a server to manage its connection, credentials and tools.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statistic(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }

    private func serverRow(_ profile: AppMCPProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: profile.kind.symbol).font(.title2)
                    .foregroundStyle(TurboFieldfareMacTheme.accentColor)
                    .frame(width: 44, height: 44)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.headline).lineLimit(1)
                    Text(profile.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { openConnection(profile.id) } label: {
                    Label("Manage", systemImage: "arrow.right").labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Manage \(profile.name)")
            }
            Divider()
            HStack {
                if manager.status(profile.id).isBusy { ProgressView().controlSize(.small) }
                else {
                    Circle().fill(statusColor(manager.status(profile.id))).frame(width: 7, height: 7)
                }
                Text(manager.status(profile.id).title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if manager.status(profile.id).isBusy || manager.status(profile.id) == .connected {
                    Button(manager.status(profile.id).isBusy ? "Cancel" : "Disconnect") { manager.disconnect(profile.id) }
                } else if profile.executable.isEmpty {
                    Button("Set Up…") { openConnection(profile.id) }
                } else {
                    Button("Connect") { manager.connect(profile.id) }
                }
            }
        }
        .padding(18).background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4), lineWidth: 0.5))
    }

    private func statusColor(_ status: AppMCPStatus) -> Color {
        switch status {
        case .connected: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

struct MCPNewConnectionView: View {
    let manager: AppMCPManager
    let saved: (UUID) -> Void
    @State private var profile: AppMCPProfile?

    var body: some View {
        Group {
            if let profile {
                MCPProfileEditor(profile: profile, manager: manager, goBack: { self.profile = nil }, saved: saved)
            } else {
                MCPConnectionPicker { profile = AppMCPProfile(kind: $0) }
            }
        }
        .frame(width: 610, height: 690)
    }
}

struct MCPConnectionPicker: View {
    @Environment(\.dismiss) private var dismiss
    let select: (AppMCPKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add MCP Server").font(.title2.weight(.semibold))
                Text("Configure a server or start from a service preset.")
                    .foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CUSTOM CONNECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    option(.stdio, title: "MCP Server", badge: "Local",
                           description: "Connect a local MCP server using its executable, arguments and credentials.")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("SERVICE PRESETS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    option(.exchange, title: "Microsoft Exchange", badge: "Preset",
                           description: "Use the included connector for read-only access to corporate mail and calendar.")
                }
                Label("Each server has its own connection settings, credentials and tool controls.", systemImage: "slider.horizontal.3")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Local process connections are supported. Remote server URLs and OAuth are not available yet.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(24)
            Spacer(minLength: 0)
            Divider()
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer() }.padding(20)
        }
        .frame(width: 610, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(TurboFieldfareMacTheme.accentColor)
    }

    private func option(_ kind: AppMCPKind, title: String, badge: String, description: String) -> some View {
        Button { select(kind) } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: kind.symbol).font(.title2).foregroundStyle(TurboFieldfareMacTheme.accentColor)
                    .frame(width: 32).padding(.top, 3)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(title).font(.headline)
                        Text(badge).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                    }
                    Text(description).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 5)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 0.5))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
