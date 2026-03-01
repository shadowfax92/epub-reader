import Foundation
import EPUBKit

struct EPUBMetadataResult {
    let title: String?
    let author: String?
}

final class EPUBParserService: Sendable {
    static let shared = EPUBParserService()

    func parseMetadata(from url: URL) throws -> EPUBMetadataResult {
        guard let document = EPUBDocument(url: url) else {
            throw EPUBError.invalidFile
        }
        return EPUBMetadataResult(
            title: document.title,
            author: document.author
        )
    }

    func parseBook(from metadata: BookMetadata) throws -> ParsedBook {
        guard let document = EPUBDocument(url: metadata.fileURL) else {
            throw EPUBError.invalidFile
        }

        var chapters: [BookChapter] = []
        var flatParagraphs: [BookParagraph] = []
        var globalWordIndex = 0
        var globalParagraphIndex = 0
        var chapterIndex = 0

        let tocTitles = extractTOCTitles(document: document)

        for spineItem in document.spine.items {
            guard let manifestItem = document.manifest.items[spineItem.idref] else { continue }
            let contentDir = document.contentDirectory

            let chapterURL = contentDir.appendingPathComponent(manifestItem.path)
            guard FileManager.default.fileExists(atPath: chapterURL.path) else { continue }

            let mediaType = manifestItem.mediaType
            guard mediaType == .xHTML else { continue }

            guard let htmlData = try? Data(contentsOf: chapterURL),
                  let html = String(data: htmlData, encoding: .utf8) else { continue }

            let chapterTitle = tocTitles[manifestItem.path] ?? tocTitles[spineItem.idref] ?? "Chapter \(chapterIndex + 1)"
            let textBlocks = extractTextBlocks(from: html)

            guard !textBlocks.isEmpty else { continue }

            var chapterParagraphs: [BookParagraph] = []

            for block in textBlocks {
                let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                let wordTexts = trimmed.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                guard !wordTexts.isEmpty else { continue }

                var words: [BookWord] = []
                for wordText in wordTexts {
                    words.append(BookWord(
                        id: globalWordIndex,
                        text: wordText,
                        paragraphId: globalParagraphIndex
                    ))
                    globalWordIndex += 1
                }

                let paragraph = BookParagraph(
                    id: globalParagraphIndex,
                    text: wordTexts.joined(separator: " "),
                    words: words,
                    chapterIndex: chapterIndex,
                    isHeading: block.isHeading
                )

                chapterParagraphs.append(paragraph)
                flatParagraphs.append(paragraph)
                globalParagraphIndex += 1
            }

            if !chapterParagraphs.isEmpty {
                chapters.append(BookChapter(
                    index: chapterIndex,
                    title: chapterTitle,
                    paragraphs: chapterParagraphs
                ))
                chapterIndex += 1
            }
        }

        return ParsedBook(
            metadata: metadata,
            chapters: chapters,
            flatParagraphs: flatParagraphs,
            totalWords: globalWordIndex
        )
    }

    private func extractTOCTitles(document: EPUBDocument) -> [String: String] {
        var titles: [String: String] = [:]
        let toc = document.tableOfContents
        collectTOCTitles(from: toc, into: &titles)
        return titles
    }

    private func collectTOCTitles(from toc: EPUBTableOfContents, into titles: inout [String: String]) {
        if let src = toc.item {
            let cleanSrc = src.components(separatedBy: "#").first ?? src
            titles[cleanSrc] = toc.label
        }
        if let subItems = toc.subTable {
            for item in subItems {
                collectTOCTitles(from: item, into: &titles)
            }
        }
    }

    // MARK: - HTML Text Extraction

    struct TextBlock {
        let text: String
        let isHeading: Bool
    }

    private func extractTextBlocks(from html: String) -> [TextBlock] {
        let parser = HTMLTextExtractor()
        return parser.extract(from: html)
    }
}

private class HTMLTextExtractor: NSObject, XMLParserDelegate {
    private var blocks: [EPUBParserService.TextBlock] = []
    private var currentText = ""
    private var isHeading = false
    private var skipContent = false
    private var insideBody = false
    private var depth = 0

    private let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "blockquote", "section", "article", "header", "footer",
        "tr", "td", "th", "dt", "dd", "figcaption", "pre"
    ]
    private let headingElements: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private let skipElements: Set<String> = ["script", "style", "head", "nav", "aside"]

    func extract(from html: String) -> [EPUBParserService.TextBlock] {
        blocks = []
        currentText = ""
        isHeading = false
        skipContent = false
        insideBody = false
        depth = 0

        // Clean up common XHTML issues for XMLParser
        var cleanHTML = html
        // Ensure it's valid XML by wrapping if needed
        if !cleanHTML.contains("<?xml") {
            cleanHTML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + cleanHTML
        }

        if let data = cleanHTML.data(using: .utf8) {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = true
            parser.shouldReportNamespacePrefixes = false
            parser.parse()
        }

        flushCurrentBlock()

        // Fallback: if XMLParser failed, use regex stripping
        if blocks.isEmpty {
            let stripped = stripHTMLWithRegex(html)
            if !stripped.isEmpty {
                let paragraphs = stripped.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                blocks = paragraphs.map { EPUBParserService.TextBlock(text: $0, isHeading: false) }
            }
        }

        return blocks
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = elementName.lowercased()

        if name == "body" { insideBody = true; return }
        if skipElements.contains(name) { skipContent = true; depth += 1; return }
        if !insideBody { return }

        if blockElements.contains(name) {
            flushCurrentBlock()
            isHeading = headingElements.contains(name)
        }

        if name == "br" {
            currentText += " "
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()

        if skipElements.contains(name) {
            depth -= 1
            if depth <= 0 { skipContent = false; depth = 0 }
            return
        }

        if name == "body" { insideBody = false; return }

        if blockElements.contains(name) {
            flushCurrentBlock()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideBody, !skipContent else { return }
        currentText += string
    }

    private func flushCurrentBlock() {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(EPUBParserService.TextBlock(text: trimmed, isHeading: isHeading))
        }
        currentText = ""
        isHeading = false
    }

    private func stripHTMLWithRegex(_ html: String) -> String {
        var result = html
        // Remove script/style blocks
        result = result.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        // Replace block elements with newlines
        result = result.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</h[1-6]>", with: "\n", options: .regularExpression)
        // Strip all remaining tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common entities
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse whitespace
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum EPUBError: LocalizedError {
    case invalidFile
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Could not open this EPUB file."
        case .parsingFailed: return "Failed to parse the EPUB content."
        }
    }
}
