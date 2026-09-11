import AppKit
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

struct RootView: View {
    let model: AppModel
    @State private var conversationChromeHeight: CGFloat = 0
    @AppStorage("TurboFieldfare.chatSidebarVisible")
    private var isChatSidebarVisible = true
    @AppStorage("TurboFieldfare.inspectorVisible")
    private var isInspectorVisible = false

    var body: some View {
        // Three columns in one HStack, not a NavigationSplitView. The split
        // view brought a second sidebar toggle of its own, moved our controls
        // whenever the sidebar opened, and left the sidebar column inert to the
        // mouse. Both side panels are now the same shape — a fixed-width column
        // beside a flexible middle — which is also what keeps a narrow window
        // from slicing one in half: the sides hold their width and the
        // transcript gives up the space.
        HStack(spacing: 0) {
            if isChatSidebarVisible {
                ChatSidebarView(model: model)
                    .frame(width: CGFloat(AppChromeLayout.chatSidebarWidth))
                    .frame(maxHeight: .infinity)
                    .background(TurboFieldfareMacTheme.sidebarBackgroundColor)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            primaryContent
                .frame(
                    minWidth: CGFloat(AppChromeLayout.primaryMinimumWidth),
                    maxWidth: .infinity,
                    maxHeight: .infinity)

            if isInspectorVisible {
                Divider()

                InspectorView(model: model)
                    .frame(width: CGFloat(AppChromeLayout.inspectorWidth))
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(
            minWidth: CGFloat(AppChromeLayout.minimumWindowWidth(
                isChatSidebarVisible: isChatSidebarVisible,
                isInspectorVisible: isInspectorVisible)),
            minHeight: CGFloat(AppChromeLayout.minimumHeight))
        .containerBackground(for: .window) {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).mix(
                        with: TurboFieldfareMacTheme.accentColor,
                        by: 0.04),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .tint(TurboFieldfareMacTheme.accentColor)
        .animation(.smooth(duration: 0.3), value: model.requiresModelInstallation)
        .animation(.smooth(duration: 0.25), value: model.error)
        .animation(.smooth(duration: 0.2), value: model.presentation.conversationAction)
        .animation(.smooth(duration: 0.22), value: isChatSidebarVisible)
        .animation(.smooth(duration: 0.22), value: isInspectorVisible)
        .transaction { transaction in
            if model.isRunning {
                transaction.animation = nil
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification)
        ) { _ in
            model.flushChatPersistence()
        }
    }

    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 320
    /// How a side panel opens and closes.
    ///
    /// Carried by `withAnimation` around the state change itself, not by an
    /// `.animation(value:)` on this view. Attached further down — to the panel
    /// frames — the surrounding `HStack` took the final widths immediately and
    /// only the panel slid. Attached here at the root it animated the whole
    /// subtree, and that swept up anything else changing in the same run loop
    /// turn: clicking a toggle put its own button into the pressed state, whose
    /// release then faded back in over the length of the slide, so the control
    /// just clicked read as having disappeared. An explicit transaction covers
    /// the state change and nothing else.
    static let panelSlide: Animation = .smooth(duration: 0.22)
    /// What the transcript keeps when both panels are open at the window's
    /// minimum width. Lower than the 720 the old two-column layout could
    /// afford, because a third panel has to come from somewhere — and the
    /// alternative, letting a panel be clipped, is the thing this layout exists
    /// to prevent.
    ///
    /// Measured against the status row, which is the widest thing this column
    /// has to hold: the two chat controls, the pill, and the Inspector toggle.
    /// At 440 the pill ran out of room and truncated the model's own name to
    /// "Gem…", which is the one string on that row that has to stay readable.
    static let transcriptMinimumWidth: CGFloat = 530

    private var primaryContent: some View {
        Group {
            if model.requiresModelInstallation {
                ModelInstallView(model: model)
            } else {
                conversationView
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            StatusHUDView(
                model: model,
                isChatSidebarVisible: isChatSidebarVisible,
                isInspectorVisible: isInspectorVisible,
                toggleChatSidebar: { isChatSidebarVisible.toggle() },
                toggleInspector: { isInspectorVisible.toggle() })
        }
    }

    private var conversationView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if model.hasOutputTranscript {
                    OutputPaneView(model: model)
                        .padding(.bottom, conversationChromeHeight)
                } else if conversationChromeHeight > 0 {
                    OutputPaneView(model: model)
                        .frame(
                            height: max(
                                0,
                                geometry.size.height - conversationChromeHeight))
                        .frame(maxHeight: .infinity, alignment: .top)
                }

                conversationChrome
                    .background {
                        GeometryReader { chromeGeometry in
                            Color.clear.preference(
                                key: ConversationChromeHeightKey.self,
                                value: chromeGeometry.size.height)
                        }
                    }
            }
            .onPreferenceChange(ConversationChromeHeightKey.self) { height in
                guard height > 0 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    conversationChromeHeight = height
                }
            }
        }
    }

    private var conversationChrome: some View {
        VStack(spacing: 10) {
            ConversationStateNoticeView(model: model)
            ErrorBanner(model: model)
            if model.canUndoClearHistory {
                HStack(spacing: 8) {
                    Label("Chat history cleared", systemImage: "trash")
                        .font(.callout)
                    Spacer()
                    Button("Undo", action: model.undoClearHistory)
                        .buttonStyle(.borderless)
                    Button(action: model.dismissClearHistoryUndo) {
                        Label("Dismiss", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.3), in: .capsule)
            }
            if model.shouldShowPromptExamples {
                PromptExamplesView { preset in
                    model.promptText = preset.prompt
                }
            }
            ModelActionBanner(model: model)
            PromptComposerView(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .animation(.smooth(duration: 0.2), value: model.promptText.isEmpty)
        .animation(.smooth(duration: 0.2), value: model.showPromptExamples)
        .animation(.smooth(duration: 0.2), value: model.showsPromptExamples)
    }

}

private struct ConversationChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
