import AppKit
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

struct InspectorView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @State private var showsAdvancedControls = false

    var body: some View {
        Form {
            if model.hasStaleLoadedRuntime {
                pendingChangesSection
            }
            if showsVisionSection {
                visionSection
            }
            responseSection
            contextSection
            advancedSection
            localAPISection
            Section("Connections") {
                Button { openWindow(id: "mcp-connections") } label: {
                    Label("Manage MCP Connections…", systemImage: "puzzlepiece.extension")
                }
                Text("Connect MCP servers, manage credentials and choose tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RunnerDiagnosticsSection(diagnostics: model.diagnostics)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.maxContextTokens) { model.persistUserSettings() }
        .onChange(of: model.temperature) { model.persistUserSettings() }
        .onChange(of: model.topKEnabled) { model.persistUserSettings() }
        .onChange(of: model.topK) { model.persistUserSettings() }
        .onChange(of: model.topPEnabled) { model.persistUserSettings() }
        .onChange(of: model.topP) { model.persistUserSettings() }
        .onChange(of: model.runtimeOptions) { model.persistUserSettings() }
    }

    /// Keep image support visible until the companion pack is installed and healthy.
    /// The empty state advertises the optional capability before the text model download.
    private var showsVisionSection: Bool {
        VisionSectionVisibility.shows(
            visionRuntimeEnabled: model.visionRuntimeEnabled,
            visionRuntimeSupported: model.isVisionRuntimeSupported,
            isModelInstalled: model.isModelInstalled,
            isVisionPackInstalled: model.isVisionPackInstalled,
            isCompanionOperationInProgress: model.isVisionCompanionOperationInProgress,
            installState: model.visionInstallState)
    }

    private var visionSection: some View {
        Section("Image Support") {
            LabeledContent("State") {
                Text(visionStatusLabel)
                    .font(.caption)
                    .foregroundStyle(visionStatusColor)
            }
            if model.isVisionRuntimeSupported && !model.isVisionPackInstalled {
                LabeledContent("Download") {
                    Text(MetricFormat.storage(
                        model.visionInstallDescriptor.approximateDownloadBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if model.isPreparingVisionSupport {
                ProgressView()
                    .controlSize(.small)
                Text("Unloading the text model before enabling image support…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let fraction = model.visionInstallProgressFraction {
                ProgressView(value: fraction)
                    .accessibilityValue(visionAccessibleProgress(fraction: fraction))
                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.percent(fraction * 100))
                    Spacer(minLength: 8)
                    if let eta = model.visionInstallETAText {
                        Text(eta)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if model.isInstallingVisionPack {
                ProgressView()
                    .controlSize(.small)
                if let eta = model.visionInstallETAText {
                    Text(eta)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if !model.isVisionRuntimeSupported {
                Text("Image support requires an M2 or newer Mac. "
                    + "Text generation remains available on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = model.visionInstallState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if case .recoverable(let message) = model.visionInstallState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if case .partial(let message) = model.visionInstallationStatus,
                      !model.isInstallingVisionPack {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if case .unsupportedLayout = model.visionInstallationStatus {
                Text("Image support needs a model directory named "
                    + "“<name>.gturbo”, which is where the companion pack lives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = model.visionInstallReadiness,
                      !model.isInstallingVisionPack {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if case .insufficientSpace(let requirement) = model.visionInstallReadiness,
                      !model.isInstallingVisionPack {
                Text("Free \(MetricFormat.storage(requirement.shortfallBytes)) more storage.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if model.isVisionCompanionOperationInProgress {
                Text("Model actions stay unavailable until this finishes. "
                    + "Your prompt, images, and transcript are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !model.isVisionPackInstalled && model.loadState.isReady {
                Text("The app will unload the model, enable image support, then load it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isVisionPackInstalled && model.loadState.isReady {
                Text("Unload the model before removing image support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if model.isPreparingVisionSupport {
                    Button("Preparing…") {}
                        .disabled(true)
                } else if model.isInstallingVisionPack {
                    Button("Cancel", action: model.cancelVisionInstall)
                        .disabled(!model.canCancelVisionInstall)
                } else if case .readyToActivate = model.visionInstallState {
                    Button("Discard", role: .destructive) {
                        model.discardVisionPackDownload()
                    }
                    .disabled(!model.canDiscardVisionPackDownload)
                    if model.isVisionRuntimeSupported {
                        Button("Enable", action: model.enableVisionPack)
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canEnableVisionPack)
                    }
                } else if model.isVisionPackInstalled {
                    Button("Remove", role: .destructive) {
                        model.requestVisionPackRemoval()
                    }
                    .disabled(!model.canRemoveVisionPack)
                } else {
                    if model.hasVisionPackDirectory {
                        Button("Remove", role: .destructive) {
                            model.requestVisionPackRemoval()
                        }
                        .disabled(!model.canRemoveVisionPack)
                    }
                    if model.hasPartialVisionPackDownload {
                        Button("Discard", role: .destructive) {
                            model.discardVisionPackDownload()
                        }
                        .disabled(!model.canDiscardVisionPackDownload)
                    }
                    if model.isVisionRuntimeSupported {
                        Button(visionInstallButtonLabel) {
                            model.enableVisionPack()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canEnableVisionPack)
                    }
                }
            }
        }
    }

    private var pendingChangesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Changes need a model reload", systemImage: "arrow.clockwise.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                if let summary = model.pendingRuntimeChangeSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Revert", action: model.discardPendingRuntimeChanges)
                    Spacer()
                    Button("Apply & Reload", action: model.reloadModel)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canReloadModel)
                }
            }
        }
    }

    private var visionInstallButtonLabel: String {
        if model.hasPartialVisionPackDownload { return "Resume & Enable" }
        if model.hasVisionPackDirectory { return "Repair & Enable" }
        return "Enable"
    }

    private func visionAccessibleProgress(fraction: Double) -> String {
        let percent = MetricFormat.percent(fraction * 100)
        guard let eta = model.visionInstallETAText else { return percent }
        return "\(percent), \(eta)"
    }

    private var visionStatusLabel: String {
        guard model.isVisionRuntimeSupported else { return "Requires M2 or newer" }
        if model.visionInstallState != .idle {
            return model.visionInstallPhaseLabel
        }
        switch model.visionInstallationStatus {
        case .missing: return "Not installed"
        case .partial: return "Needs repair"
        case .complete: return "Installed"
        case .unsupportedLayout: return "Not available for this model"
        }
    }

    private var visionStatusColor: Color {
        guard model.isVisionRuntimeSupported else { return .secondary }
        switch model.visionInstallationStatus {
        case .partial: return .orange
        case .missing, .complete, .unsupportedLayout: return .secondary
        }
    }

    private var responseSection: some View {
        Section("Response") {
            Picker("Style", selection: responseStyleBinding) {
                ForEach(AppResponseStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            Text(model.responseStyle.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(model.isRunning || model.loadState.isLoading
            || model.isVisionCompanionOperationInProgress
            || model.isLocalServerActive)
    }

    private var contextSection: some View {
        Section("Context") {
            LabeledContent("Window") {
                Picker("Context", selection: $model.maxContextTokens) {
                    ForEach(AppContextLengthOption.allCases) { option in
                        Text(option.menuLabel).tag(option.tokens)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("Larger contexts retain more conversation and document text, but reserve more memory after reloading.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(model.isRunning || model.loadState.isLoading
            || model.isVisionCompanionOperationInProgress
            || model.isLocalServerActive)
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced controls", isExpanded: $showsAdvancedControls) {
                VStack(alignment: .leading, spacing: 14) {
                    modelControls
                    Divider()
                    samplingControls
                    Divider()
                    runtimeControls
                    Divider()
                    Button("Reset All Settings", action: model.resetUserSettings)
                }
                .padding(.top, 8)
            }
        }
        .disabled(model.isRunning || model.loadState.isLoading
            || model.isVisionCompanionOperationInProgress
            || model.isLocalServerActive)
    }

    private var localAPISection: some View {
        Section("Local API") {
            LabeledContent("State") {
                Text(localServerStatusLabel)
                    .font(.caption)
                    .foregroundStyle(localServerStatusColor)
            }
            LabeledContent("Base URL") {
                Text(model.localServerBaseURL.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Text(localServerDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .failed(let message) = model.localServerState {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if model.localServerState == .waitingForModelUnload
                || model.localServerState == .starting
                || model.localServerState == .stopping {
                ProgressView()
                    .controlSize(.small)
            }
            if !model.localServerLog.isEmpty {
                DisclosureGroup("Server log") {
                    Text(model.localServerLog)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if model.isLocalServerActive {
                    Button("Stop Server", action: model.stopLocalServer)
                        .disabled(!model.canStopLocalServer)
                } else {
                    Button("Start Server", action: model.startLocalServer)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartLocalServer)
                }
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(serverCommand, forType: .string)
                }
            }
        }
    }

    private var localServerStatusLabel: String {
        switch model.localServerState {
        case .stopped: "Stopped"
        case .waitingForModelUnload: "Unloading app model"
        case .starting: "Starting"
        case .running:
            model.localServerProcessIdentifier.map { "Running · PID \($0)" }
                ?? "Running"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }

    private var localServerStatusColor: Color {
        switch model.localServerState {
        case .running: .green
        case .waitingForModelUnload, .starting, .stopping: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var localServerDetail: String {
        switch model.localServerState {
        case .running:
            "The OpenAI-compatible API is available on this Mac only."
        case .waitingForModelUnload, .starting:
            "The server is taking ownership of the model. Startup can take several minutes."
        case .stopping:
            "Stopping the owned server and returning the model to the app."
        case .stopped, .failed:
            if model.loadState.isReady {
                "Starting the server unloads the app model and restores it after Stop."
            } else {
                "Start the OpenAI-compatible server on 127.0.0.1 without leaving the app."
            }
        }
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupLabel("Model & memory")
            LabeledContent("Path") {
                HStack(spacing: 6) {
                    Text(model.modelPathText)
                        .font(.caption)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .help(model.modelPathText)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.modelPathText, forType: .string)
                    } label: {
                        Label("Copy model path", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Choose Model Folder…") {
                ModelLocationPicker.choose(for: model)
            }
            .disabled(model.isLocalServerActive)
            if model.canUnloadModel {
                Button("Unload Model", action: model.unloadModel)
            }
            LabeledContent("State") {
                Text(model.presentation.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.requiresModelInstallation {
                LabeledContent("Download") {
                    Text(MetricFormat.storage(model.installDescriptor.approximateDownloadBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Installed size") {
                    Text(MetricFormat.storage(model.installDescriptor.installedBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let requirement = model.installRequirement {
                    LabeledContent("Available") {
                        Text(MetricFormat.storage(requirement.availableBytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Expert cache") {
                Picker("Expert cache", selection: $model.runtimeOptions.expertCacheSlots) {
                    ForEach(AppRuntimeOptions.allowedSlotCounts, id: \.self) { slots in
                        Text(AppRuntimeOptions.slotsLabel(for: slots)).tag(slots)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            Text("More cache slots may improve decode speed and use more RAM. This setting applies after reloading.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var samplingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupLabel("Sampling · next request")
            LabeledContent("Temperature") {
                HStack(spacing: 8) {
                    Slider(value: $model.temperature, in: 0...2, step: 0.05)
                    Text(model.temperature, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Toggle("Top-K", isOn: $model.topKEnabled)
            if model.topKEnabled {
                LabeledContent("K value") {
                    Stepper(value: $model.topK, in: 1...256) {
                        Text("\(model.topK)").monospacedDigit()
                    }
                    .fixedSize()
                }
            }
            Toggle("Top-P", isOn: $model.topPEnabled)
                .disabled(!model.topKEnabled)
            if model.topKEnabled && model.topPEnabled {
                LabeledContent("P value") {
                    HStack(spacing: 8) {
                        Slider(value: $model.topP, in: 0.01...1, step: 0.01)
                        Text(model.topP, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var runtimeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupLabel("Runtime")
            Toggle("Prompt prefill", isOn: $model.runtimeOptions.prefillEnabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("RDADVISE")
                Picker("RDADVISE", selection: $model.runtimeOptions.rdadvisePolicy) {
                    ForEach(AppRDAdvicePolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Text("RDADVISE is experimental and applies after reloading. Prompt prefill applies to the next request.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }

    private var responseStyleBinding: Binding<AppResponseStyle> {
        Binding(
            get: { model.responseStyle },
            set: { model.applyResponseStyle($0) })
    }

    private var serverCommand: String {
        let escapedPath = model.modelPathText.replacingOccurrences(
            of: "'", with: "'\\''")
        let options = model.runtimeOptions
        return "swift run -c release TurboFieldfareServer"
            + " --model '\(escapedPath)'"
            + " --port \(model.localServerPort)"
            + " --max-context \(model.maxContextTokens)"
            + " --expert-cache-slots \(options.expertCacheSlots)"
            + " --expert-cache-policy \(options.expertCachePolicy.rawValue)"
            + " --prefill \(options.prefillEnabled ? "on" : "off")"
            + " --prefill-chunk-tokens \(options.prefillChunkTokens)"
            + " --rdadvise \(options.rdadvisePolicy.rawValue)"
            + " --vision-residency \(options.visionResidencyPolicy.rawValue)"
    }
}
