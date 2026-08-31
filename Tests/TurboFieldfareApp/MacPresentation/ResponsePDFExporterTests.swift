import Foundation
import PDFKit
import Testing
@testable import TurboFieldfareMacPresentation

@MainActor
@Suite struct ResponsePDFExporterTests {
    @Test func exportsMarkdownResponseAsSearchablePDF() throws {
        let data = try ResponsePDFExporter.makePDF(
            title: "Quarterly summary",
            response: "# Result\n\nRevenue grew **12%**.\n\n- Stable demand\n- Lower costs",
            createdAt: Date(timeIntervalSince1970: 0))
        let document = try #require(PDFDocument(data: data))
        let text = document.pagesText

        #expect(document.pageCount == 1)
        #expect(text.contains("Quarterly summary"))
        #expect(text.contains("Revenue grew 12%."))
        #expect(text.contains("Stable demand"))
        #expect(text.contains("Page 1 of 1"))
    }

    @Test func paginatesLongResponsesAndNumbersEveryPage() throws {
        let paragraph = "A concise paragraph with enough words to exercise PDF pagination."
        let response = Array(repeating: paragraph, count: 240)
            .joined(separator: "\n\n")

        let data = try ResponsePDFExporter.makePDF(
            title: "Long answer",
            response: response,
            createdAt: Date(timeIntervalSince1970: 0))
        let document = try #require(PDFDocument(data: data))

        #expect(document.pageCount > 1)
        for pageIndex in 0..<document.pageCount {
            let page = try #require(document.page(at: pageIndex))
            #expect(page.string?.contains(
                "Page \(pageIndex + 1) of \(document.pageCount)") == true)
        }
    }

    @Test func rejectsEmptyResponse() {
        #expect(throws: ResponsePDFExportError.emptyResponse) {
            _ = try ResponsePDFExporter.makePDF(
                title: "Empty",
                response: " \n ")
        }
    }
}

private extension PDFDocument {
    var pagesText: String {
        (0..<pageCount).compactMap { page(at: $0)?.string }
            .joined(separator: "\n")
    }
}
