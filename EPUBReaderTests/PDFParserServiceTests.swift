import XCTest
import PDFKit
@testable import EPUBReader

@MainActor
final class PDFParserServiceTests: XCTestCase {

    // MARK: - Metadata

    func testParseMetadataReadsDocumentAttributes() throws {
        let url = try PDFTestFixtures.makePDF(
            pages: ["Hello world"],
            title: "Test Title",
            author: "Test Author"
        )
        let result = PDFParserService.shared.parseMetadata(from: url)
        XCTAssertEqual(result.title, "Test Title")
        XCTAssertEqual(result.author, "Test Author")
    }

    func testParseMetadataWithoutAttributesReturnsNils() throws {
        let url = try PDFTestFixtures.makePDF(pages: ["Hello world"])
        let result = PDFParserService.shared.parseMetadata(from: url)
        XCTAssertNil(result.title)
        XCTAssertNil(result.author)
    }

    func testParseMetadataUnreadableFileReturnsNils() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing.pdf")
        let result = PDFParserService.shared.parseMetadata(from: url)
        XCTAssertNil(result.title)
        XCTAssertNil(result.author)
    }

    // MARK: - parseBook

    private func makeMetadata(fileName: String = "test.pdf") -> BookMetadata {
        BookMetadata(id: UUID(), title: "T", author: "A", fileName: fileName, dateAdded: Date())
    }

    private func parseFixture(pages: [String]) throws -> ParsedPDFBook {
        let url = try PDFTestFixtures.makePDF(pages: pages)
        guard let document = PDFDocument(url: url) else {
            throw NSError(domain: "PDFParserServiceTests", code: 1)
        }
        return PDFParserService.shared.parseBook(from: makeMetadata(), document: document)
    }

    func testParseBookStructureAndGlobalIndices() throws {
        let parsed = try parseFixture(pages: [
            "First page has some words here.",
            "Second page brings more words to read.",
        ])
        let book = parsed.book

        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "Page 1")
        XCTAssertEqual(book.chapters[1].title, "Page 2")

        let allWords = book.flatParagraphs.flatMap(\.words)
        XCTAssertEqual(allWords.map(\.id), Array(0..<book.totalWords))
        XCTAssertEqual(parsed.wordLocations.count, book.totalWords)
        XCTAssertGreaterThan(book.totalWords, 0)

        for paragraph in book.flatParagraphs {
            for word in paragraph.words {
                XCTAssertEqual(
                    parsed.wordLocations[word.id].pageIndex,
                    parsed.chapterPageIndices[paragraph.chapterIndex]
                )
            }
        }
    }

    func testParseBookWordGeometryAlignment() throws {
        let url = try PDFTestFixtures.makePDF(
            pages: ["The quick brown fox jumps over the lazy dog today."]
        )
        let document = try XCTUnwrap(PDFDocument(url: url))
        let parsed = PDFParserService.shared.parseBook(from: makeMetadata(), document: document)

        XCTAssertGreaterThan(parsed.book.totalWords, 0)
        for paragraph in parsed.book.flatParagraphs {
            for word in paragraph.words {
                let location = parsed.wordLocations[word.id]
                let page = try XCTUnwrap(document.page(at: location.pageIndex))
                let pageString = try XCTUnwrap(page.string)
                let raw = (pageString as NSString).substring(with: location.range)
                XCTAssertEqual(raw, word.text, "range must reproduce the word's source text")
            }
        }
    }

    func testEmptyPageSkippedWithoutBreakingContinuity() throws {
        let parsed = try parseFixture(pages: ["Words on page one.", "", "Words on page three."])
        let book = parsed.book

        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "Page 1")
        XCTAssertEqual(book.chapters[1].title, "Page 3")
        XCTAssertEqual(parsed.chapterPageIndices, [0, 2])

        let allWords = book.flatParagraphs.flatMap(\.words)
        XCTAssertEqual(allWords.map(\.id), Array(0..<book.totalWords))
    }

    func testFullyEmptyPDFParsesToZeroWords() throws {
        let parsed = try parseFixture(pages: ["", ""])
        XCTAssertEqual(parsed.book.totalWords, 0)
        XCTAssertTrue(parsed.book.chapters.isEmpty)
        XCTAssertTrue(parsed.wordLocations.isEmpty)
    }

    func testResourceHrefAndChapterIndex() throws {
        let parsed = try parseFixture(pages: ["Some words here on the first page."])
        let paragraph = try XCTUnwrap(parsed.book.flatParagraphs.first)
        XCTAssertEqual(paragraph.resourceHref, "page=1")
        XCTAssertEqual(paragraph.chapterIndex, 0)
    }
}
