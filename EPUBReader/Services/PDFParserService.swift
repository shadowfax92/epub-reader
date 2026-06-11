import Foundation
import PDFKit

struct PDFMetadataResult {
    let title: String?
    let author: String?
}

enum PDFError: LocalizedError {
    case invalidFile
    case passwordProtected

    var errorDescription: String? {
        switch self {
        case .invalidFile: return "Could not open this PDF file."
        case .passwordProtected: return "This PDF is password-protected and can't be imported."
        }
    }
}

struct PDFWordLocation: Equatable {
    let pageIndex: Int
    /// UTF-16 range in the page's extracted string — the coordinate space `PDFPage.selection(for:)` expects.
    let range: NSRange
}

struct ParsedPDFBook {
    let book: ParsedBook
    /// Indexed by global word id (`BookWord.id`); count == `book.totalWords`.
    let wordLocations: [PDFWordLocation]
    /// Chapter index → physical page index (chapters exist only for pages with text).
    let chapterPageIndices: [Int]
}

/// PDF counterpart of EPUBParserService: extracts import metadata and book content via PDFKit.
/// Stateless and nonisolated so parsing can run off the main actor (PDFKit models are
/// thread-safe for reading; only PDFView is main-thread-bound).
final class PDFParserService: Sendable {
    static let shared = PDFParserService()

    func parseMetadata(from url: URL) -> PDFMetadataResult {
        guard let document = PDFDocument(url: url) else {
            return PDFMetadataResult(title: nil, author: nil)
        }
        return parseMetadata(from: document)
    }

    func parseMetadata(from document: PDFDocument) -> PDFMetadataResult {
        let attributes = document.documentAttributes ?? [:]
        return PDFMetadataResult(
            title: nonEmptyAttribute(attributes[PDFDocumentAttribute.titleAttribute]),
            author: nonEmptyAttribute(attributes[PDFDocumentAttribute.authorAttribute])
        )
    }

    private func nonEmptyAttribute(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }

    /// Builds the same `ParsedBook` shape the EPUB parser produces (chapters = pages with text),
    /// plus a geometry side-table mapping every global word id to its page + character range.
    func parseBook(from metadata: BookMetadata, document: PDFDocument) -> ParsedPDFBook {
        var chapters: [BookChapter] = []
        var flatParagraphs: [BookParagraph] = []
        var wordLocations: [PDFWordLocation] = []
        var chapterPageIndices: [Int] = []
        var globalWordIndex = 0
        var globalParagraphIndex = 0

        for pageIndex in 0..<document.pageCount {
            if Task.isCancelled { break } // reader was dismissed mid-parse; partial result is discarded
            guard let page = document.page(at: pageIndex),
                  let pageString = page.string else { continue }

            let blocks = PDFTextExtractor.paragraphs(from: pageString)
            guard !blocks.isEmpty else { continue }

            let chapterIndex = chapters.count
            var chapterParagraphs: [BookParagraph] = []

            for block in blocks {
                var words: [BookWord] = []
                for token in block.tokens {
                    words.append(BookWord(
                        id: globalWordIndex,
                        text: token.text,
                        paragraphId: globalParagraphIndex
                    ))
                    wordLocations.append(PDFWordLocation(pageIndex: pageIndex, range: token.range))
                    globalWordIndex += 1
                }

                let paragraph = BookParagraph(
                    id: globalParagraphIndex,
                    text: words.map(\.text).joined(separator: " "),
                    words: words,
                    chapterIndex: chapterIndex,
                    isHeading: false,
                    resourceHref: "page=\(pageIndex + 1)"
                )
                chapterParagraphs.append(paragraph)
                flatParagraphs.append(paragraph)
                globalParagraphIndex += 1
            }

            chapters.append(BookChapter(
                index: chapterIndex,
                title: "Page \(pageIndex + 1)",
                paragraphs: chapterParagraphs
            ))
            chapterPageIndices.append(pageIndex)
        }

        let book = ParsedBook(
            metadata: metadata,
            chapters: chapters,
            flatParagraphs: flatParagraphs,
            totalWords: globalWordIndex
        )
        return ParsedPDFBook(
            book: book,
            wordLocations: wordLocations,
            chapterPageIndices: chapterPageIndices
        )
    }
}
