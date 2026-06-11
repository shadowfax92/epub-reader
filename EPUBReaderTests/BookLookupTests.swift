import XCTest
@testable import EPUBReader

final class BookLookupTests: XCTestCase {

    // MARK: - ParsedBook.paragraph(withId:)

    func testParagraphLookupOnWellFormedBook() {
        let book = makeBook(paragraphWordCounts: [3, 2, 4])

        XCTAssertEqual(book.paragraph(withId: 0)?.text, book.flatParagraphs[0].text)
        XCTAssertEqual(book.paragraph(withId: 2)?.id, 2)
        XCTAssertNil(book.paragraph(withId: 3))
        XCTAssertNil(book.paragraph(withId: -1))
    }

    func testParagraphLookupFallsBackWhenIdsAreNotIndices() {
        // ids deliberately violate the id == index invariant
        let paragraphs = [makeParagraph(id: 7, wordIds: [0, 1]),
                          makeParagraph(id: 3, wordIds: [2, 3])]
        let book = ParsedBook(metadata: makeMetadata(), chapters: [], flatParagraphs: paragraphs, totalWords: 4)

        XCTAssertEqual(book.paragraph(withId: 3)?.id, 3)
        XCTAssertEqual(book.paragraph(withId: 7)?.id, 7)
        XCTAssertNil(book.paragraph(withId: 5))
    }

    // MARK: - BookParagraph.position(ofGlobalWordId:)

    func testWordPositionWithContiguousIds() {
        let paragraph = makeParagraph(id: 0, wordIds: [10, 11, 12, 13])

        XCTAssertEqual(paragraph.position(ofGlobalWordId: 10), 0)
        XCTAssertEqual(paragraph.position(ofGlobalWordId: 12), 2)
        XCTAssertEqual(paragraph.position(ofGlobalWordId: 13), 3)
        XCTAssertNil(paragraph.position(ofGlobalWordId: 9))
        XCTAssertNil(paragraph.position(ofGlobalWordId: 14))
    }

    func testWordPositionFallsBackWhenIdsNotContiguous() {
        let paragraph = makeParagraph(id: 0, wordIds: [10, 20, 30])

        XCTAssertEqual(paragraph.position(ofGlobalWordId: 20), 1)
        XCTAssertEqual(paragraph.position(ofGlobalWordId: 30), 2)
        XCTAssertNil(paragraph.position(ofGlobalWordId: 25))
    }

    func testWordPositionEmptyParagraph() {
        let paragraph = BookParagraph(id: 0, text: "", words: [], chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml")
        XCTAssertNil(paragraph.position(ofGlobalWordId: 0))
    }

    // MARK: - [BookParagraph].indexOfParagraph(containingWordId:)

    func testIndexOfParagraphBoundaries() {
        let paragraphs = [makeParagraph(id: 0, wordIds: [0, 1, 2]),
                          makeParagraph(id: 1, wordIds: [3, 4]),
                          makeParagraph(id: 2, wordIds: [5, 6, 7, 8])]

        XCTAssertEqual(paragraphs.indexOfParagraph(containingWordId: 0), 0)
        XCTAssertEqual(paragraphs.indexOfParagraph(containingWordId: 2), 0) // last word of p0
        XCTAssertEqual(paragraphs.indexOfParagraph(containingWordId: 3), 1) // first word of p1
        XCTAssertEqual(paragraphs.indexOfParagraph(containingWordId: 8), 2)
        XCTAssertNil(paragraphs.indexOfParagraph(containingWordId: 9))
        XCTAssertNil(paragraphs.indexOfParagraph(containingWordId: -1))
    }

    func testIndexOfParagraphEmptyArray() {
        XCTAssertNil([BookParagraph]().indexOfParagraph(containingWordId: 0))
    }

    func testIndexOfParagraphFallsBackOnUnorderedRanges() {
        // word ranges out of order (invariant broken) — linear fallback must still find it
        let paragraphs = [makeParagraph(id: 0, wordIds: [5, 6]),
                          makeParagraph(id: 1, wordIds: [0, 1])]

        XCTAssertEqual(paragraphs.indexOfParagraph(containingWordId: 1), 1)
        XCTAssertEqual(paragraphs.indexOfParagraph(containingWordId: 6), 0)
    }

    // MARK: - Fixtures

    private func makeMetadata() -> BookMetadata {
        BookMetadata(id: UUID(), title: "T", author: "A", fileName: "t.epub", dateAdded: Date())
    }

    private func makeParagraph(id: Int, wordIds: [Int]) -> BookParagraph {
        let words = wordIds.map { BookWord(id: $0, text: "w\($0)", paragraphId: id) }
        return BookParagraph(
            id: id,
            text: words.map(\.text).joined(separator: " "),
            words: words,
            chapterIndex: 0,
            isHeading: false,
            resourceHref: "ch1.xhtml"
        )
    }

    /// Builds a well-formed book honoring the parser invariants:
    /// paragraph id == flat index, word ids globally contiguous.
    private func makeBook(paragraphWordCounts: [Int]) -> ParsedBook {
        var paragraphs: [BookParagraph] = []
        var wordId = 0
        for (paraId, count) in paragraphWordCounts.enumerated() {
            let ids = Array(wordId..<(wordId + count))
            paragraphs.append(makeParagraph(id: paraId, wordIds: ids))
            wordId += count
        }
        return ParsedBook(metadata: makeMetadata(), chapters: [], flatParagraphs: paragraphs, totalWords: wordId)
    }
}
