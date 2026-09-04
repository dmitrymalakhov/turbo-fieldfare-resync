import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

struct GenerateControl: View {
    let model: AppModel
    private let controlHeight: CGFloat = 34

    var body: some View {
        if model.isRunning {
            runningPill
        } else if model.isPreparingSubmission {
            preparingPill
        } else {
            generateButton
        }
    }

    private var generateButton: some View {
        Button {
            model.submitPrompt()
        } label: {
            Label(submitTitle, systemImage: "arrow.up")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 24)
                .frame(minWidth: 124, minHeight: controlHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(TurboFieldfareMacTheme.accentColor, in: .capsule)
        .overlay {
            Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canSubmitPrompt)
        .opacity(model.canSubmitPrompt ? 1 : 0.62)
    }

    private var submitTitle: String {
        if model.canRun { return "Send" }
        if model.canReloadModel { return "Apply & Send" }
        if model.canLoadModel { return "Load & Send" }
        return "Send"
    }

    private var preparingPill: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Loading…")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 18)
        .frame(minWidth: 124, minHeight: controlHeight)
        .foregroundStyle(.secondary)
        .background(.quaternary.opacity(0.35), in: .capsule)
        .accessibilityLabel("Loading the model before sending")
    }

    private var runningPill: some View {
        Button {
            model.cancel()
        } label: {
            HStack(spacing: 10) {
                if model.isCancellationPending {
                    Text("Stopping")
                        .font(.callout.weight(.medium))
                } else if model.externalContextProgress != nil {
                    Text("Loading data…").font(.callout.weight(.medium))
                } else if model.phase == .prefill || model.phase == .compressing {
                    Text(model.presentation.label)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Text("\(MetricFormat.rate(model.liveTokensPerSecond)) tok/s")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Label("Stop generation", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(.callout)
                    .frame(width: 28, height: 28)
            }
            .padding(.leading, 18)
            .padding(.trailing, 4)
            .frame(minWidth: 140, minHeight: controlHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(TurboFieldfareMacTheme.accentColor, in: .capsule)
        .overlay {
            Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(!model.canCancel)
        .help("Stop generation")
        .animation(.smooth(duration: 0.2), value: model.presentation.label)
    }
}
