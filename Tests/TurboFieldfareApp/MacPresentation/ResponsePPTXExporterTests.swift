import Foundation
import Testing
@testable import TurboFieldfareMacPresentation

@Suite struct ResponsePPTXExporterTests {
    private let sample = """
    # Slide 1 - Локальная аналитика
    - Решения остаются на устройстве
    Speaker notes: Представьте основную идею.

    # Slide 2 - Что получает команда
    - Поисковый PDF
    - Редактируемый PowerPoint
    Suggested visual: Схема локального потока данных
    Speaker notes: Подчеркните отсутствие внешней отправки данных.
    """

    @Test func parsesSlidesBulletsVisualsAndNotes() throws {
        let draft = try ResponsePresentationDraftParser.parse(
            sample,
            title: "Обзор - presentation")

        #expect(draft.title == "Обзор")
        #expect(draft.slides.count == 2)
        #expect(draft.slides[0].title == "Локальная аналитика")
        #expect(draft.slides[0].speakerNotes == "Представьте основную идею.")
        #expect(draft.slides[1].bullets == [
            "Поисковый PDF",
            "Редактируемый PowerPoint",
        ])
        #expect(draft.slides[1].suggestedVisual
            == "Схема локального потока данных")
    }

    @Test func parserAcceptsRussianSlideHeadingsAndNumberedBullets() throws {
        let draft = try ResponsePresentationDraftParser.parse(
            """
            ## Слайд 1: Заголовок
            1. Первый пункт
            2) Второй пункт
            Заметки: Комментарий
            """,
            title: "")

        #expect(draft.title == "Заголовок")
        #expect(draft.slides[0].bullets == ["Первый пункт", "Второй пункт"])
        #expect(draft.slides[0].speakerNotes == "Комментарий")
    }

    @Test func createsAValidEditablePowerPointPackage() throws {
        let data = try ResponsePPTXExporter.makePPTX(
            title: "Обзор - presentation",
            response: sample,
            createdAt: Date(timeIntervalSince1970: 0))
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("presentation.pptx")
        try data.write(to: url)

        try validateZip(url)
        let extracted = try DocumentTextExtractor.extract(from: url)

        #expect(data.starts(with: [0x50, 0x4B]))
        #expect(extracted.formatLabel == "PowerPoint")
        #expect(extracted.text.contains("Локальная аналитика"))
        #expect(extracted.text.contains("Редактируемый PowerPoint"))
        #expect(extracted.text.contains("2 / 2"))

    }

    @Test func rejectsResponsesWithoutSlideSections() {
        #expect(throws: ResponsePresentationExportError.noSlides) {
            _ = try ResponsePPTXExporter.makePPTX(
                title: "Not slides",
                response: "A regular answer without slide headings")
        }
    }

    private func validateZip(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ResponsePPTXExporterTests-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        return root
    }
}
