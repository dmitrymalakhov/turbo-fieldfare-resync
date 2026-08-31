import AppKit
import CoreGraphics
import Foundation

public enum ResponsePDFExportError: LocalizedError, Equatable, Sendable {
    case emptyResponse
    case layoutFailed
    case renderingFailed

    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "The response is empty."
        case .layoutFailed:
            return "The response could not be laid out for PDF export."
        case .renderingFailed:
            return "The PDF document could not be rendered."
        }
    }
}

@MainActor
public enum ResponsePDFExporter {
    public static let pageSize = CGSize(width: 595.28, height: 841.89)

    private static let horizontalMargin: CGFloat = 54
    private static let topMargin: CGFloat = 50
    private static let bottomMargin: CGFloat = 58
    private static let footerHeight: CGFloat = 18
    private static let maximumPageCount = 10_000

    public static func makePDF(
        title: String,
        response: String,
        createdAt: Date = Date()
    ) throws -> Data {
        guard !response.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            throw ResponsePDFExportError.emptyResponse
        }

        let document = makeDocument(
            title: title,
            response: response,
            createdAt: createdAt)
        let textStorage = NSTextStorage(attributedString: document)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let contentSize = CGSize(
            width: pageSize.width - horizontalMargin * 2,
            height: pageSize.height - topMargin - bottomMargin - footerHeight)
        var pageContainers: [NSTextContainer] = []
        var laidOutGlyphs = 0

        repeat {
            guard pageContainers.count < maximumPageCount else {
                throw ResponsePDFExportError.layoutFailed
            }
            let container = NSTextContainer(containerSize: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            guard glyphRange.length > 0 || layoutManager.numberOfGlyphs == 0 else {
                throw ResponsePDFExportError.layoutFailed
            }
            laidOutGlyphs = max(laidOutGlyphs, NSMaxRange(glyphRange))
            pageContainers.append(container)
        } while laidOutGlyphs < layoutManager.numberOfGlyphs

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw ResponsePDFExportError.renderingFailed
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let metadata = [
            kCGPDFContextTitle as String: resolvedTitle(title),
            kCGPDFContextCreator as String: "TurboFieldfare",
        ] as CFDictionary
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            metadata) else {
            throw ResponsePDFExportError.renderingFailed
        }

        for (index, container) in pageContainers.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)

            let previousContext = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(
                cgContext: context,
                flipped: true)
            let glyphRange = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: horizontalMargin, y: topMargin)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            drawFooter(
                page: index + 1,
                total: pageContainers.count,
                in: CGRect(
                    x: horizontalMargin,
                    y: pageSize.height - bottomMargin + 18,
                    width: contentSize.width,
                    height: footerHeight))
            NSGraphicsContext.current = previousContext

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        guard output.length > 0 else {
            throw ResponsePDFExportError.renderingFailed
        }
        return output as Data
    }

    private static func makeDocument(
        title: String,
        response: String,
        createdAt: Date
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacing = 8
        output.append(NSAttributedString(
            string: resolvedTitle(title) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: headingStyle,
            ]))

        let metadataStyle = NSMutableParagraphStyle()
        metadataStyle.paragraphSpacing = 20
        output.append(NSAttributedString(
            string: "Generated locally with TurboFieldfare - \(dateString(createdAt))\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5),
                .foregroundColor: NSColor.darkGray,
                .paragraphStyle: metadataStyle,
            ]))

        let renderedResponse = NSMutableAttributedString(
            attributedString: ResponseMarkdownRenderer().render(response).attributedString)
        if renderedResponse.length > 0 {
            renderedResponse.addAttribute(
                .foregroundColor,
                value: NSColor.black,
                range: NSRange(location: 0, length: renderedResponse.length))
        }
        output.append(renderedResponse)
        return output
    }

    private static func drawFooter(page: Int, total: Int, in rect: CGRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        NSAttributedString(
            string: "Page \(page) of \(total)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.darkGray,
                .paragraphStyle: style,
            ]).draw(in: rect)
    }

    private static func resolvedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "TurboFieldfare response" : trimmed
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
