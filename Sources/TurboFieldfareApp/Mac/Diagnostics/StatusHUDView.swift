import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

struct StatusHUDView: View {
    @Environment(\.openWindow) private var openWindow
    var hasConnectedMail = false
    let model: AppModel
    let isChatSidebarVisible: Bool
    let isInspectorVisible: Bool
    let toggleChatSidebar: () -> Void
    let toggleInspector: () -> Void

    var body: some View {
        strip
            .padding(.top, 10)
            .padding(
                .horizontal,
                CGFloat(AppChromeLayout.headerHorizontalPadding))
    }

    /// One spacing for the whole row: panel edge to button, button to pill,
    /// pill to button, button to panel edge. Two different values — 20 outside
    /// and 10 either side of the pill — made the controls read as sitting
    /// closer to the pill on one side than the other even though the numbers
    /// mirrored.
    private static let gap: CGFloat = 12

    private var strip: some View {
        HStack(spacing: 12) {
            chatSidebarToggle
            Divider().frame(height: 16)
            ModelStatusBadge(model: model)
            selectedChatTitle
            Divider().frame(height: 16)
            PhaseLabel(model: model)
            if let action = model.presentation.primaryAction {
                HeaderModelActionButton(model: model, action: action)
            }
            Spacer(minLength: 12)
            if showsMetrics {
                HUDMetricView(value: rateText, label: "tok/s", animated: !model.isRunning,
                              identifier: .hudRate)
                if showsContext {
                    // No info button beside this one. The memory figure has one
                    // because `phys_footprint` is genuinely misread; "20/8.2K"
                    // is not, and the same words are on hover.
                    HUDMetricView(value: contextText, label: "context",
                                  animated: !model.isRunning, identifier: .hudContext)
                        .help(contextHelp)
                }
                HStack(spacing: 2) {
                    HUDMetricView(value: memoryText, label: "memory", animated: !model.isRunning,
                                  identifier: .hudMemory)
                        .help(memoryHelp)
                    InfoPopoverButton(subject: "Memory", text: memoryHelp, arrowEdge: .bottom)
                        .accessibilityIdentifier(.hudMemoryInfo)
                }
            }
            if hasConnectedMail {
            Button { openWindow(id: "mail") } label: {
                Label("Почта", systemImage: "envelope")
            }.buttonStyle(.borderless).help("Письма, поиск, контакты и группы")
            }
            Button { openWindow(id: "mcp-connections") } label: {
                Label("Connections", systemImage: "puzzlepiece.extension")
                    .labelStyle(.iconOnly).frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).help("Manage MCP servers, credentials and tools")
            inspectorToggle
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    Capsule().stroke(.separator.opacity(0.5), lineWidth: 0.5)
                }
        }
        .gesture(WindowDragGesture())
    }

    /// Show or hide the chat list, and start a new chat.
    ///
    /// These lived in the window toolbar, beside the traffic lights. That put
    /// them in a strip of their own above the content, in a corner with no
    /// relation to anything. They belong on the one row this window uses for
    /// its chrome, at the end nearest the list they open.
    private var chatControls: some View {
        HStack(spacing: 4) {
            StripControlButton(
                systemImage: "sidebar.leading",
                help: WindowControlsPresentation.sidebarToggleHelp(
                    isVisible: model.isSidebarVisible),
                identifier: .stripSidebar,
                action: { withAnimation(RootView.panelSlide) { model.toggleSidebar() } })

            StripControlButton(
                systemImage: "square.and.pencil",
                help: WindowControlsPresentation.newChatHelp,
                identifier: .stripNewChat,
                action: model.newChat)
                .disabled(!model.canStartNewChat)
        }
    }

    /// The mirror of the sidebar toggle, at the end of the row nearest the
    /// panel it controls.
    /// Shown once a conversation is holding anything. A gauge that reads 0 for
    /// the whole of a single-prompt session is noise.
    private var showsContext: Bool {
        liveContextTokens.map { $0 > 0 } ?? !model.conversation.isEmpty
    }

    /// The KV position now, not at the end of the last turn.
    private var liveContextTokens: Int? {
        guard model.isRunning else { return model.conversation.kvTokens }
        guard model.livePrefillDone > 0 || model.liveTokenCount > 0 else {
            return model.conversation.kvTokens
        }
        return ConversationContextPresentation.liveTokens(
            prefillDone: model.livePrefillDone,
            prefillTotal: model.livePrefillTotal,
            generated: model.liveTokenCount,
            committed: model.conversation.kvTokens ?? 0)
    }

    private var contextText: String {
        guard let liveContextTokens else { return "\u{2014}" }
        return ConversationContextPresentation.gauge(
            kvTokens: liveContextTokens,
            maxContext: model.effectiveMaxContextTokens)
    }

    private var contextHelp: String {
        guard let liveContextTokens else {
            return "The decode service did not report the committed context position. "
                + "Start a new chat before adding images."
        }
        return ConversationContextPresentation.explanation(
            kvTokens: liveContextTokens,
            maxContext: model.effectiveMaxContextTokens,
            cachedTokens: model.diagnostics?.cachedPromptTokens)
    }

    private var chatSidebarToggle: some View {
        let presentation = AppSidebarControlPresentation(
            sidebar: .chats,
            isVisible: isChatSidebarVisible)
        return Button(action: toggleChatSidebar) {
            Label(
                presentation.title,
                systemImage: presentation.systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isChatSidebarVisible ? .primary : .secondary)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(presentation.help)
        .accessibilityValue(presentation.accessibilityValue)
    }

    private var selectedChatTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left")
                .foregroundStyle(.secondary)
            Text(model.selectedChat.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if model.selectedChat.contextSummary?.isEmpty == false {
                Image(systemName: "brain")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Older turns are kept in compressed memory")
            }
        }
        .frame(maxWidth: 180)
        .help(model.selectedChat.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current chat")
        .accessibilityValue(model.selectedChat.title)
    }

    private var inspectorToggle: some View {
        let presentation = AppSidebarControlPresentation(
            sidebar: .inspector,
            isVisible: isInspectorVisible)
        return Button(action: toggleInspector) {
            Label(
                presentation.title,
                systemImage: presentation.systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isInspectorVisible ? .primary : .secondary)
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .help(presentation.help)
        .accessibilityValue(presentation.accessibilityValue)
    }

    private var rateText: String {
        if model.phase == .decode { return MetricFormat.rate(model.liveTokensPerSecond) }
        if let d = model.diagnostics { return MetricFormat.rate(d.tokensPerSecond) }
        return "\u{2014}"
    }


    /// `phys_footprint`: what this process is charged. Measured, not assumed —
    /// the model and image tower weights are memory-mapped and read by the GPU,
    /// and no per-process counter attributes them: 1,144 MB of tower retained
    /// moves the footprint by 5 MB. Those bytes are page cache, owned by the
    /// kernel and reclaimable, so the popover explains them in words and the
    /// diagnostics section carries their measured row.
    private var memoryText: String {
        MetricFormat.memory(model.currentProcessMemoryBytes)
    }

    private var memoryHelp: String {
        MemoryFootprintExplanation.text(chargedBytes: model.currentProcessMemoryBytes)
    }

    private var showsMetrics: Bool {
        model.loadState.isReady || model.isRunning || model.diagnostics != nil
    }
}

private struct HeaderModelActionButton: View {
    var hasConnectedMail = false
    let model: AppModel
    let action: AppModelAction

    var body: some View {
        let presentation = AppModelActionPresentation(action: action)
        Button {
            model.perform(action)
        } label: {
            Label(presentation.title, systemImage: presentation.systemImage)
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(presentation.isCancellation
              ? .orange
              : TurboFieldfareMacTheme.accentColor)
        .help(presentation.help)
        .accessibilityHint(presentation.help)
    }
}

private struct PhaseLabel: View {
    var hasConnectedMail = false
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            switch content {
            case .loading(let label):
                ProgressView().controlSize(.mini)
                Text(label)
            case .pulse(let label):
                PulsingDot()
                Text(label)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            case .steady(let label):
                Circle().fill(TurboFieldfareMacTheme.accentColor).frame(width: 7, height: 7)
                Text(label).contentTransition(.opacity)
            case .quiet(let label):
                Text(label)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model status")
        .accessibilityValue(model.presentation.label)
        .accessibilityIdentifier(.hudPhase)
    }

    private enum Content {
        case loading(String)
        case pulse(String)
        case steady(String)
        case quiet(String)
    }

    private var content: Content {
        let presentation = model.presentation
        if presentation.showsActivity { return .loading(presentation.label) }
        if model.isRunning, !model.isSelectedChatRunning,
           let title = model.activeRunChatTitle {
            return .pulse("Generating in \(title)")
        }
        if model.isRunning
            && (model.phase == .prefill || model.phase == .compressing) {
            return .pulse(presentation.label)
        }
        if model.isRunning && model.phase == .decode { return .steady(presentation.label) }
        return .quiet(presentation.label)
    }
}

private struct PulsingDot: View {
    var body: some View {
        Circle()
            .fill(TurboFieldfareMacTheme.accentColor)
            .frame(width: 7, height: 7)
            .phaseAnimator([0.4, 1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
    }
}

/// One icon control on the status row, beside the pill.
///
/// Plain, not bordered: the pill is the only filled shape on this row, and
/// giving each toggle one of its own would put three competing capsules across
/// the top of the window. The hover highlight is what says it is pressable.
private struct StripControlButton: View {
    let systemImage: String
    let help: String
    let identifier: AccessibilityID
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 32, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering && isEnabled
                              ? Color.primary.opacity(0.09)
                              : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(StripControlButtonStyle())
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
    }
}

/// Press feedback that owns its own timing.
///
/// `.plain` dims the label while the mouse is down and restores it on release —
/// inside whatever animation is in flight. Clicking a panel toggle starts one
/// that covers the window, so the button that was just pressed faded back in
/// over the whole slide and read as having disappeared. This says how long a
/// press takes and refuses the ambient transaction.
private struct StripControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
