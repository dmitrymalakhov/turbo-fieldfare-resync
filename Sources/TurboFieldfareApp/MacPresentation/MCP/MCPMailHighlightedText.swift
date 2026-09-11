import AppKit
import SwiftUI
import TurboFieldfareAppCore

func mailHitColor(_ kind: AppMCPMailSearchHit.Kind) -> Color {
    switch kind {
    case .query: .yellow
    case .assignment: .orange
    case .deadline: .blue
    case .identity: .green
    case .phrase: .purple
    }
}

func highlightedMailText(_ text: String, hits: [AppMCPMailSearchHit]) -> AttributedString {
    var value = AttributedString(text)
    for hit in hits {
        guard let range = Range(hit.range, in: text), let start = AttributedString.Index(range.lowerBound, within: value),
              let end = AttributedString.Index(range.upperBound, within: value) else { continue }
        value[start..<end].backgroundColor = mailHitColor(hit.kind).opacity(0.3)
        value[start..<end].font = .body.bold()
    }
    return value
}

struct MCPMailHighlightedBody: View {
    let text: String
    let hits: [AppMCPMailSearchHit]
    @State private var index = 0
    private var locations: [AppMCPMailSearchHit] {
        var seen = Set<Int>()
        return hits.filter { seen.insert($0.range.location).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !locations.isEmpty {
                HStack {
                    Text("Совпадение \(min(index + 1, locations.count)) из \(locations.count)").font(.caption)
                    Spacer()
                    Button { index = (index + locations.count - 1) % locations.count } label: { Label("Предыдущее совпадение", systemImage: "chevron.up").labelStyle(.iconOnly) }
                    Button { index = (index + 1) % locations.count } label: { Label("Следующее совпадение", systemImage: "chevron.down").labelStyle(.iconOnly) }
                }
            }
            MailSearchTextView(text: text, hits: hits, focused: locations.isEmpty ? nil : locations[min(index, locations.count - 1)].range)
        }
        .onChange(of: hits) { _, _ in index = 0 }
        .onChange(of: text) { _, _ in index = 0 }
    }
}

/// NSTextView preserves full-text selection/copy and scrolls to an exact UTF-16 match.
private struct MailSearchTextView: NSViewRepresentable {
    let text: String
    let hits: [AppMCPMailSearchHit]
    let focused: NSRange?
    final class Coordinator {
        var text: String?
        var hits: [AppMCPMailSearchHit] = []
        var focused: NSRange?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false; view.isSelectable = true
        view.drawsBackground = false; scroll.drawsBackground = false
        view.textContainerInset = NSSize(width: 4, height: 8)
        view.isAutomaticLinkDetectionEnabled = false
        view.setAccessibilityLabel("Полный текст письма с найденными совпадениями")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let changed = context.coordinator.text != text || context.coordinator.hits != hits
        if changed {
            let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
            for hit in hits where hit.range.location >= 0 && NSMaxRange(hit.range) <= value.length {
                value.addAttributes([.backgroundColor: NSColor(mailHitColor(hit.kind)).withAlphaComponent(0.3),
                                     .underlineStyle: NSUnderlineStyle.single.rawValue], range: hit.range)
            }
            view.textStorage?.setAttributedString(value)
            context.coordinator.text = text; context.coordinator.hits = hits
        }
        if changed || context.coordinator.focused != focused {
            if let focused, NSMaxRange(focused) <= (text as NSString).length {
                view.scrollRangeToVisible(focused)
                view.showFindIndicator(for: focused)
            } else if changed { view.scrollToBeginningOfDocument(nil) }
            context.coordinator.focused = focused
        }
    }
}
