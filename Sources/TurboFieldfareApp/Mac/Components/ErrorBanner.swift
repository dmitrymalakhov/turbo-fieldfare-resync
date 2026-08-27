import AppKit
import TurboFieldfareAppCore
import TurboFieldfareMacPresentation
import SwiftUI

struct ErrorBanner: View {
    @Bindable var model: AppModel
    @State private var showsDetails = false

    var body: some View {
        if let error = model.error,
           GenericErrorBannerPolicy.shouldShow(error: error, loadState: model.loadState) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error.userMessage)
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Details") {
                    showsDetails.toggle()
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Error Details")
                            .font(.headline)
                        Text(error.technicalDetail)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Spacer()
                            Button("Copy Details") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    error.technicalDetail,
                                    forType: .string)
                            }
                        }
                    }
                    .padding(16)
                    .frame(width: 420)
                }
                Button {
                    model.error = nil
                } label: {
                    Label("Dismiss error", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Capsule().stroke(.red.opacity(0.55), lineWidth: 1)
                    }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
