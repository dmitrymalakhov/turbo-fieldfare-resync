import Foundation

public struct ResponsePresentationSlide: Equatable, Sendable {
    public let title: String
    public let bullets: [String]
    public let suggestedVisual: String?
    public let speakerNotes: String?

    public init(
        title: String,
        bullets: [String],
        suggestedVisual: String? = nil,
        speakerNotes: String? = nil
    ) {
        self.title = title
        self.bullets = bullets
        self.suggestedVisual = suggestedVisual
        self.speakerNotes = speakerNotes
    }
}

public struct ResponsePresentationDraft: Equatable, Sendable {
    public let title: String
    public let slides: [ResponsePresentationSlide]

    public init(title: String, slides: [ResponsePresentationSlide]) {
        self.title = title
        self.slides = slides
    }
}

public enum ResponsePresentationExportError: LocalizedError, Equatable, Sendable {
    case noSlides
    case packageCreationFailed
    case archiveCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSlides:
            return "No '# Slide N - Title' sections were found in the response."
        case .packageCreationFailed:
            return "The PowerPoint package could not be created."
        case .archiveCreationFailed(let detail):
            return "The PowerPoint file could not be archived: \(detail)"
        }
    }
}

public enum ResponsePresentationDraftParser {
    public static func parse(
        _ markdown: String,
        title: String
    ) throws -> ResponsePresentationDraft {
        var slides: [ResponsePresentationSlide] = []
        var builder: SlideBuilder?

        for rawLine in markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if let slideTitle = parseSlideTitle(line) {
                if let builder {
                    slides.append(builder.build())
                }
                builder = SlideBuilder(title: slideTitle)
                continue
            }
            guard var current = builder, !line.isEmpty else { continue }

            if let visual = value(
                in: line,
                labels: [
                    "suggested visual", "visual",
                    "рекомендуемый визуал", "визуал",
                ]) {
                current.suggestedVisual = cleanMarkdown(visual)
                current.collectsNotes = false
            } else if let notes = value(
                in: line,
                labels: [
                    "speaker notes", "notes",
                    "заметки докладчика", "заметки",
                ]) {
                current.speakerNoteLines.append(cleanMarkdown(notes))
                current.collectsNotes = true
            } else if current.collectsNotes {
                current.speakerNoteLines.append(cleanMarkdown(line))
            } else if let bullet = bulletText(line) {
                current.bullets.append(cleanMarkdown(bullet))
            } else if !line.hasPrefix("```") {
                current.bullets.append(cleanMarkdown(line))
            }
            builder = current
        }

        if let builder {
            slides.append(builder.build())
        }
        slides = slides.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !slides.isEmpty else {
            throw ResponsePresentationExportError.noSlides
        }
        return ResponsePresentationDraft(
            title: resolvedDeckTitle(title, firstSlide: slides.first),
            slides: slides)
    }

    private struct SlideBuilder {
        var title: String
        var bullets: [String] = []
        var suggestedVisual: String?
        var speakerNoteLines: [String] = []
        var collectsNotes = false

        func build() -> ResponsePresentationSlide {
            ResponsePresentationSlide(
                title: title,
                bullets: bullets.filter { !$0.isEmpty },
                suggestedVisual: suggestedVisual?.nilIfEmpty,
                speakerNotes: speakerNoteLines
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                    .nilIfEmpty)
        }
    }

    private static func parseSlideTitle(_ line: String) -> String? {
        let pattern = #"^#{1,3}\s*(?:Slide|Слайд)\s+\d+\s*[-—:]\s*(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return cleanMarkdown(String(line[range])).nilIfEmpty
    }

    private static func value(in line: String, labels: [String]) -> String? {
        let normalized = line
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
        let lowercased = normalized.lowercased()
        for label in labels {
            for separator in [":", " - ", " — "] {
                let prefix = label + separator
                guard lowercased.hasPrefix(prefix) else { continue }
                return String(normalized.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func bulletText(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        let pattern = #"^\d+[.)]\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    private static func cleanMarkdown(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["**", "__", "`"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        if let expression = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\([^\)]+\)"#) {
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: "$1")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvedDeckTitle(
        _ title: String,
        firstSlide: ResponsePresentationSlide?
    ) -> String {
        let suffix = " - presentation"
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasSuffix(suffix) {
            let base = String(cleaned.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty { return base }
        }
        if !cleaned.isEmpty { return cleaned }
        return firstSlide?.title ?? "Presentation"
    }
}

public enum ResponsePPTXExporter {
    private static let slideWidth = 12_192_000
    private static let slideHeight = 6_858_000
    private static let emuPerInch = 914_400

    public static func makePPTX(
        title: String,
        response: String,
        createdAt: Date = Date()
    ) throws -> Data {
        let draft = try ResponsePresentationDraftParser.parse(
            response,
            title: title)
        return try makePPTX(from: draft, createdAt: createdAt)
    }

    public static func makePPTX(
        from draft: ResponsePresentationDraft,
        createdAt: Date = Date()
    ) throws -> Data {
        guard !draft.slides.isEmpty else {
            throw ResponsePresentationExportError.noSlides
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "TurboFieldfare-PPTX-\(UUID().uuidString)",
            isDirectory: true)
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        let archive = root.appendingPathComponent("presentation.pptx")
        defer { try? fileManager.removeItem(at: root) }

        do {
            try fileManager.createDirectory(
                at: contents,
                withIntermediateDirectories: true)
            let parts = packageParts(for: draft, createdAt: createdAt)
            for (path, text) in parts {
                let url = contents.appendingPathComponent(path)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            }
        } catch {
            throw ResponsePresentationExportError.packageCreationFailed
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, "."]
        process.currentDirectoryURL = contents
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ResponsePresentationExportError.archiveCreationFailed(
                error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8) ?? "zip exited with status \(process.terminationStatus)"
            throw ResponsePresentationExportError.archiveCreationFailed(
                detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            let data = try Data(contentsOf: archive)
            guard data.starts(with: [0x50, 0x4B]) else {
                throw ResponsePresentationExportError.packageCreationFailed
            }
            return data
        } catch let exportError as ResponsePresentationExportError {
            throw exportError
        } catch {
            throw ResponsePresentationExportError.packageCreationFailed
        }
    }

    private static func packageParts(
        for draft: ResponsePresentationDraft,
        createdAt: Date
    ) -> [String: String] {
        var parts: [String: String] = [
            "[Content_Types].xml": contentTypes(slideCount: draft.slides.count),
            "_rels/.rels": rootRelationships,
            "docProps/core.xml": coreProperties(
                title: draft.title,
                createdAt: createdAt),
            "docProps/app.xml": appProperties(slideCount: draft.slides.count),
            "ppt/presentation.xml": presentationXML(slideCount: draft.slides.count),
            "ppt/_rels/presentation.xml.rels": presentationRelationships(
                slideCount: draft.slides.count),
            "ppt/theme/theme1.xml": themeXML,
            "ppt/slideMasters/slideMaster1.xml": slideMasterXML,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": slideMasterRelationships,
            "ppt/slideLayouts/slideLayout1.xml": slideLayoutXML,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": slideLayoutRelationships,
        ]
        for (index, slide) in draft.slides.enumerated() {
            let number = index + 1
            parts["ppt/slides/slide\(number).xml"] = slideXML(
                slide,
                number: number,
                total: draft.slides.count)
            parts["ppt/slides/_rels/slide\(number).xml.rels"] = slideRelationships
        }
        return parts
    }

    private static func contentTypes(slideCount: Int) -> String {
        let slides = (1...slideCount).map {
            "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }.joined()
        return xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
          <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
          <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
          <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
          \(slides)
        </Types>
        """
    }

    private static let rootRelationships = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    private static func coreProperties(title: String, createdAt: Date) -> String {
        let timestamp = ISO8601DateFormatter().string(from: createdAt)
        return xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(xmlEscape(title))</dc:title>
          <dc:creator>TurboFieldfare</dc:creator>
          <cp:lastModifiedBy>TurboFieldfare</cp:lastModifiedBy>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(timestamp)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static func appProperties(slideCount: Int) -> String {
        xmlHeader + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
          <Application>TurboFieldfare</Application>
          <PresentationFormat>Widescreen</PresentationFormat>
          <Slides>\(slideCount)</Slides>
          <Notes>0</Notes>
          <HiddenSlides>0</HiddenSlides>
          <MMClips>0</MMClips>
          <ScaleCrop>false</ScaleCrop>
          <LinksUpToDate>false</LinksUpToDate>
          <SharedDoc>false</SharedDoc>
          <HyperlinksChanged>false</HyperlinksChanged>
          <AppVersion>1.0</AppVersion>
        </Properties>
        """
    }

    private static func presentationXML(slideCount: Int) -> String {
        let slideIDs = (1...slideCount).map {
            "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 1)\"/>"
        }.joined()
        return xmlHeader + """
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
          <p:sldIdLst>\(slideIDs)</p:sldIdLst>
          <p:sldSz cx="\(slideWidth)" cy="\(slideHeight)" type="screen16x9"/>
          <p:notesSz cx="6858000" cy="9144000"/>
          <p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr><a:lvl1pPr><a:defRPr lang="en-US"/></a:lvl1pPr></p:defaultTextStyle>
        </p:presentation>
        """
    }

    private static func presentationRelationships(slideCount: Int) -> String {
        let slides = (1...slideCount).map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\($0).xml\"/>"
        }.joined()
        return xmlHeader + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
          \(slides)
        </Relationships>
        """
    }

    private static let slideMasterRelationships = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
    </Relationships>
    """

    private static let slideLayoutRelationships = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
    </Relationships>
    """

    private static let slideRelationships = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
    </Relationships>
    """

    private static let slideMasterXML = xmlHeader + """
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:cSld><p:spTree>\(groupShapeXML)</p:spTree></p:cSld>
      <p:clrMap accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" bg1="lt1" bg2="lt2" folHlink="folHlink" hlink="hlink" tx1="dk1" tx2="dk2"/>
      <p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst>
      <p:hf dt="0" hdr="0" ftr="0" sldNum="0"/>
      <p:txStyles>
        <p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="3600" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="Helvetica Neue"/></a:defRPr></a:lvl1pPr></p:titleStyle>
        <p:bodyStyle><a:lvl1pPr marL="342900" indent="-228600"><a:defRPr sz="2200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="Helvetica Neue"/></a:defRPr></a:lvl1pPr></p:bodyStyle>
        <p:otherStyle><a:defPPr><a:defRPr sz="1800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="Helvetica Neue"/></a:defRPr></a:defPPr></p:otherStyle>
      </p:txStyles>
    </p:sldMaster>
    """

    private static let slideLayoutXML = xmlHeader + """
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
      <p:cSld name="Blank"><p:spTree>\(groupShapeXML)</p:spTree></p:cSld>
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
    </p:sldLayout>
    """

    private static let themeXML = xmlHeader + """
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="TurboFieldfare">
      <a:themeElements>
        <a:clrScheme name="TurboFieldfare Grid">
          <a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
          <a:dk2><a:srgbClr val="1F2933"/></a:dk2><a:lt2><a:srgbClr val="EDEDED"/></a:lt2>
          <a:accent1><a:srgbClr val="3D8DFF"/></a:accent1><a:accent2><a:srgbClr val="6DCBF4"/></a:accent2>
          <a:accent3><a:srgbClr val="D0EDFA"/></a:accent3><a:accent4><a:srgbClr val="B8BCC4"/></a:accent4>
          <a:accent5><a:srgbClr val="667085"/></a:accent5><a:accent6><a:srgbClr val="344054"/></a:accent6>
          <a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="TurboFieldfare Sans">
          <a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="Helvetica Neue"/><a:cs typeface="Helvetica Neue"/></a:majorFont>
          <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="Helvetica Neue"/><a:cs typeface="Helvetica Neue"/></a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="TurboFieldfare Clean">
          <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
          <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst>
          <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
          <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
        </a:fmtScheme>
      </a:themeElements>
      <a:objectDefaults/><a:extraClrSchemeLst/>
    </a:theme>
    """

    private static func slideXML(
        _ slide: ResponsePresentationSlide,
        number: Int,
        total: Int
    ) -> String {
        let isTitleSlide = number == 1
        var nextID = 2
        var shapes: [String] = []

        if isTitleSlide {
            shapes.append(textBox(
                id: nextID,
                name: "Deck label",
                x: inches(0.82), y: inches(0.55),
                width: inches(3.2), height: inches(0.35),
                paragraphs: [paragraph("TurboFieldfare", size: 1400, color: "667085")]))
            nextID += 1
            shapes.append(rectangle(
                id: nextID,
                name: "Accent rule",
                x: inches(0.82), y: inches(3.45),
                width: inches(1.65), height: inches(0.045),
                color: "3D8DFF"))
            nextID += 1
            shapes.append(textBox(
                id: nextID,
                name: "Presentation title",
                x: inches(0.82), y: inches(3.72),
                width: inches(11.4), height: inches(1.45),
                paragraphs: [paragraph(
                    limited(slide.title, characters: 72),
                    size: 5000,
                    bold: true,
                    color: "000000")],
                anchor: "b"))
            nextID += 1
            let subtitle = slide.bullets.prefix(2).map {
                paragraph(limited($0, characters: 130), size: 2000, color: "344054")
            }
            if !subtitle.isEmpty {
                shapes.append(textBox(
                    id: nextID,
                    name: "Presentation subtitle",
                    x: inches(0.82), y: inches(5.45),
                    width: inches(10.8), height: inches(0.9),
                    paragraphs: subtitle))
                nextID += 1
            }
        } else {
            shapes.append(textBox(
                id: nextID,
                name: "Deck label",
                x: inches(0.78), y: inches(0.38),
                width: inches(3.0), height: inches(0.3),
                paragraphs: [paragraph("TurboFieldfare", size: 1200, color: "667085")]))
            nextID += 1
            shapes.append(textBox(
                id: nextID,
                name: "Slide title",
                x: inches(0.78), y: inches(0.82),
                width: inches(11.65), height: inches(0.85),
                paragraphs: [paragraph(
                    limited(slide.title, characters: 64),
                    size: 3600,
                    bold: true,
                    color: "000000")]))
            nextID += 1
            shapes.append(rectangle(
                id: nextID,
                name: "Divider",
                x: inches(0.78), y: inches(1.82),
                width: inches(11.75), height: inches(0.018),
                color: "B8BCC4"))
            nextID += 1

            let bullets = Array(slide.bullets.prefix(5))
            let bodyParagraphs = (bullets.isEmpty ? [" "] : bullets).map {
                paragraph(
                    limited($0, characters: 175),
                    size: 2200,
                    color: "1F2933",
                    bullet: !bullets.isEmpty)
            }
            let inset = number.isMultiple(of: 2) ? 1.25 : 0.98
            shapes.append(textBox(
                id: nextID,
                name: "Slide content",
                x: inches(inset), y: inches(2.22),
                width: inches(11.25 - inset + 0.78), height: inches(4.15),
                paragraphs: bodyParagraphs))
            nextID += 1
        }

        shapes.append(textBox(
            id: nextID,
            name: "Slide number",
            x: inches(11.72), y: inches(7.06),
            width: inches(0.8), height: inches(0.22),
            paragraphs: [paragraph("\(number) / \(total)", size: 1000, color: "667085", alignment: "r")]))

        return xmlHeader + """
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld>
            <p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
            <p:spTree>\(groupShapeXML)\(shapes.joined())</p:spTree>
          </p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sld>
        """
    }

    private static func textBox(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        paragraphs: [String],
        anchor: String = "t"
    ) -> String {
        """
        <p:sp>
          <p:nvSpPr><p:cNvPr id="\(id)" name="\(xmlEscape(name))"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr>
          <p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="\(anchor)"/><a:lstStyle/>\(paragraphs.joined())</p:txBody>
        </p:sp>
        """
    }

    private static func rectangle(
        id: Int,
        name: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        color: String
    ) -> String {
        """
        <p:sp>
          <p:nvSpPr><p:cNvPr id="\(id)" name="\(xmlEscape(name))"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(color)"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
        </p:sp>
        """
    }

    private static func paragraph(
        _ text: String,
        size: Int,
        bold: Bool = false,
        color: String,
        bullet: Bool = false,
        alignment: String = "l"
    ) -> String {
        let bulletProperties = bullet
            ? "<a:pPr algn=\"\(alignment)\" marL=\"365760\" indent=\"-228600\"><a:lnSpc><a:spcPct val=\"112000\"/></a:lnSpc><a:spcAft><a:spcPts val=\"850\"/></a:spcAft><a:buFont typeface=\"Helvetica Neue\"/><a:buChar char=\"•\"/></a:pPr>"
            : "<a:pPr algn=\"\(alignment)\"><a:lnSpc><a:spcPct val=\"108000\"/></a:lnSpc><a:spcAft><a:spcPts val=\"450\"/></a:spcAft><a:buNone/></a:pPr>"
        let boldValue = bold ? " b=\"1\"" : ""
        return """
        <a:p>\(bulletProperties)<a:r><a:rPr lang="en-US" sz="\(size)" kern="1200"\(boldValue)><a:solidFill><a:srgbClr val="\(color)"/></a:solidFill><a:latin typeface="Helvetica Neue"/><a:ea typeface="Helvetica Neue"/><a:cs typeface="Helvetica Neue"/></a:rPr><a:t>\(xmlEscape(text))</a:t></a:r><a:endParaRPr lang="en-US" sz="\(size)"/></a:p>
        """
    }

    private static let groupShapeXML = """
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
    """

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    private static func inches(_ value: Double) -> Int {
        Int((value * Double(emuPerInch)).rounded())
    }

    private static func limited(_ text: String, characters: Int) -> String {
        guard text.count > characters else { return text }
        return String(text.prefix(max(0, characters - 1))) + "…"
    }

    private static func xmlEscape(_ source: String) -> String {
        let allowed = source.unicodeScalars.filter { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || scalar.value >= 0x20
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
