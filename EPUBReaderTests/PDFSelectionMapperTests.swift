import XCTest
@testable import EPUBReader

final class PDFSelectionMapperTests: XCTestCase {

    private let pages = [
        "the cat and the dog run fast.\nAnother line of page one.",
        "beta gamma here too plus the dog again.",
    ]

    /// Assembles paragraphs + word locations from page strings the same way PDFParserService does.
    private func assemble(_ pages: [String]) -> (paragraphs: [BookParagraph], locations: [PDFWordLocation]) {
        var paragraphs: [BookParagraph] = []
        var locations: [PDFWordLocation] = []
        var wordId = 0
        var paragraphId = 0

        for (pageIndex, pageString) in pages.enumerated() {
            for block in PDFTextExtractor.paragraphs(from: pageString) {
                var words: [BookWord] = []
                for token in block.tokens {
                    words.append(BookWord(id: wordId, text: token.text, paragraphId: paragraphId))
                    locations.append(PDFWordLocation(pageIndex: pageIndex, range: token.range))
                    wordId += 1
                }
                paragraphs.append(BookParagraph(
                    id: paragraphId,
                    text: words.map(\.text).joined(separator: " "),
                    words: words,
                    chapterIndex: pageIndex,
                    isHeading: false,
                    resourceHref: "page=\(pageIndex + 1)"
                ))
                paragraphId += 1
            }
        }
        return (paragraphs, locations)
    }

    private func word(_ id: Int, in paragraphs: [BookParagraph]) -> BookWord? {
        paragraphs.flatMap(\.words).first { $0.id == id }
    }

    func testExactMatchMapsToFirstWordOfSelection() {
        let (paragraphs, locations) = assemble(pages)
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "Another line",
            selectionStartOffset: nil,
            pageIndex: 0,
            pageString: pages[0],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertEqual(word(result?.wordIndex ?? -1, in: paragraphs)?.text, "Another")
        XCTAssertEqual(result?.paragraphIndex, 0)
    }

    func testRepeatedWordDisambiguatedByPhraseOffset() {
        let (paragraphs, locations) = assemble(pages)
        // "the" occurs at word 0 and word 3; the phrase "the dog run" starts at the second one.
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "the dog run",
            selectionStartOffset: nil,
            pageIndex: 0,
            pageString: pages[0],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertEqual(result?.wordIndex, 3)
    }

    func testExplicitOffsetDisambiguates() {
        let (paragraphs, locations) = assemble(pages)
        let offset = (pages[1] as NSString).range(of: "the dog again").location
        XCTAssertNotEqual(offset, NSNotFound)

        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "the",
            selectionStartOffset: offset,
            pageIndex: 1,
            pageString: pages[1],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        let matched = word(result?.wordIndex ?? -1, in: paragraphs)
        XCTAssertEqual(matched?.text, "the")
        XCTAssertEqual(locations[result?.wordIndex ?? 0].pageIndex, 1)
    }

    func testWhitespaceMismatchFallsBackToFirstWordOnPage() {
        let (paragraphs, locations) = assemble(pages)
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "beta  gamma",
            selectionStartOffset: nil,
            pageIndex: 1,
            pageString: pages[1],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertEqual(word(result?.wordIndex ?? -1, in: paragraphs)?.text, "beta")
        XCTAssertEqual(locations[result?.wordIndex ?? 0].pageIndex, 1)
    }

    func testSelectionNotOnPageReturnsNil() {
        let (paragraphs, locations) = assemble(pages)
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "zebra",
            selectionStartOffset: nil,
            pageIndex: 0,
            pageString: pages[0],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertNil(result)
    }

    func testPageBoundaryRespected() throws {
        let (paragraphs, locations) = assemble(pages)
        // "the dog" exists on both pages; pageIndex 1 must map to the page-1 occurrence.
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "the dog",
            selectionStartOffset: nil,
            pageIndex: 1,
            pageString: pages[1],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertEqual(locations[try XCTUnwrap(result).wordIndex].pageIndex, 1)
        XCTAssertEqual(word(result?.wordIndex ?? -1, in: paragraphs)?.text, "the")
    }

    func testMisfiredOffsetFallsBackToExactSearch() {
        let (paragraphs, locations) = assemble(pages)
        // Offset points at "cat" but the selection is "dog run" — the geometric probe
        // misfired; mapping must reject it and use the exact text search instead.
        let catOffset = (pages[0] as NSString).range(of: "cat").location
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "dog run",
            selectionStartOffset: catOffset,
            pageIndex: 0,
            pageString: pages[0],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertEqual(word(result?.wordIndex ?? -1, in: paragraphs)?.text, "dog")
    }

    func testOffsetAcceptedForPartialWordSelection() {
        let (paragraphs, locations) = assemble(pages)
        // Selecting a fragment inside a word ("amma" of "gamma") still maps to that word.
        let offset = (pages[1] as NSString).range(of: "amma").location
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "amma",
            selectionStartOffset: offset,
            pageIndex: 1,
            pageString: pages[1],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertEqual(word(result?.wordIndex ?? -1, in: paragraphs)?.text, "gamma")
    }

    func testEmptySelectionReturnsNil() {
        let (paragraphs, locations) = assemble(pages)
        let result = PDFSelectionMapper.findStartPosition(
            selectionText: "   \n ",
            selectionStartOffset: nil,
            pageIndex: 0,
            pageString: pages[0],
            paragraphs: paragraphs,
            wordLocations: locations
        )
        XCTAssertNil(result)
    }
}
