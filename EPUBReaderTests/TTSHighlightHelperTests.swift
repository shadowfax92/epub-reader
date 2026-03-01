import XCTest
@testable import EPUBReader

final class TTSHighlightHelperTests: XCTestCase {

    // MARK: - hrefsMatch

    func testExactMatch() {
        XCTAssertTrue(TTSHighlightHelper.hrefsMatch("OEBPS/Text/ch1.xhtml", "OEBPS/Text/ch1.xhtml"))
    }

    func testFragmentStripping() {
        XCTAssertTrue(TTSHighlightHelper.hrefsMatch("OEBPS/Text/ch1.xhtml#section1", "OEBPS/Text/ch1.xhtml"))
        XCTAssertTrue(TTSHighlightHelper.hrefsMatch("OEBPS/Text/ch1.xhtml", "OEBPS/Text/ch1.xhtml#section1"))
    }

    func testSuffixMatch() {
        // Absolute URL vs relative path
        XCTAssertTrue(TTSHighlightHelper.hrefsMatch("OEBPS/Text/ch1.xhtml", "Text/ch1.xhtml"))
        XCTAssertTrue(TTSHighlightHelper.hrefsMatch("Text/ch1.xhtml", "OEBPS/Text/ch1.xhtml"))
    }

    func testNoMatch() {
        XCTAssertFalse(TTSHighlightHelper.hrefsMatch("OEBPS/Text/ch1.xhtml", "OEBPS/Text/ch2.xhtml"))
    }

    func testSuffixFalsePositivePrevented() {
        // ch11.xhtml should NOT match ch1.xhtml — requires path separator
        XCTAssertFalse(TTSHighlightHelper.hrefsMatch("OEBPS/Text/ch11.xhtml", "ch1.xhtml"))
        XCTAssertFalse(TTSHighlightHelper.hrefsMatch("ch1.xhtml", "OEBPS/Text/ch11.xhtml"))
    }

    // MARK: - buildTextContext

    func testContextFirstWord() {
        let words = makeWords(["Hello", "world", "this", "is", "a", "test"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 0)
        XCTAssertNil(ctx.before)
        XCTAssertEqual(ctx.highlight, "Hello")
        XCTAssertEqual(ctx.after, "world this is a test")
    }

    func testContextLastWord() {
        let words = makeWords(["Hello", "world", "test"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 2)
        XCTAssertEqual(ctx.before, "Hello world")
        XCTAssertEqual(ctx.highlight, "test")
        XCTAssertNil(ctx.after)
    }

    func testContextMiddleWord() {
        let words = makeWords(["The", "quick", "brown", "fox", "jumped"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 2)
        XCTAssertEqual(ctx.before, "The quick")
        XCTAssertEqual(ctx.highlight, "brown")
        XCTAssertEqual(ctx.after, "fox jumped")
    }

    func testFullParagraphContextUsedNotJustEightWords() {
        // This is the critical test: with a long paragraph, ALL words should be included
        // in context, not just 8. The old code used .suffix(8) / .prefix(8).
        let wordTexts = (0..<50).map { "word\($0)" }
        let words = makeWords(wordTexts)

        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 25)

        // Before should contain ALL 25 preceding words, not just 8
        let beforeWords = ctx.before!.components(separatedBy: " ")
        XCTAssertEqual(beforeWords.count, 25)
        XCTAssertEqual(beforeWords.first, "word0")
        XCTAssertEqual(beforeWords.last, "word24")

        // After should contain ALL 24 following words, not just 8
        let afterWords = ctx.after!.components(separatedBy: " ")
        XCTAssertEqual(afterWords.count, 24)
        XCTAssertEqual(afterWords.first, "word26")
        XCTAssertEqual(afterWords.last, "word49")
    }

    func testContextWithCommonWord() {
        // Simulates "the" appearing multiple times — full context should disambiguate
        let words = makeWords(["Albert", "Einstein", "was", "born", "in", "Ulm", "in", "the", "Kingdom"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 4) // first "in"
        XCTAssertEqual(ctx.before, "Albert Einstein was born")
        XCTAssertEqual(ctx.highlight, "in")
        XCTAssertEqual(ctx.after, "Ulm in the Kingdom")
    }

    func testContextSingleWordParagraph() {
        let words = makeWords(["Title"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 0)
        XCTAssertNil(ctx.before)
        XCTAssertEqual(ctx.highlight, "Title")
        XCTAssertNil(ctx.after)
    }

    func testContextOutOfBoundsPosition() {
        let words = makeWords(["Hello", "world"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: 5)
        XCTAssertNil(ctx.before)
        XCTAssertEqual(ctx.highlight, "")
        XCTAssertNil(ctx.after)
    }

    func testContextNegativePosition() {
        let words = makeWords(["Hello"])
        let ctx = TTSHighlightHelper.buildTextContext(words: words, wordPosition: -1)
        XCTAssertNil(ctx.before)
        XCTAssertEqual(ctx.highlight, "")
        XCTAssertNil(ctx.after)
    }

    // MARK: - findStartPosition

    func testFindStartPositionExactMatch() {
        let paragraphs = [
            BookParagraph(id: 0, text: "Hello world", words: makeWords(["Hello", "world"], startId: 0), chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml"),
            BookParagraph(id: 1, text: "Goodbye world", words: makeWords(["Goodbye", "world"], startId: 2), chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml"),
        ]

        let result = TTSHighlightHelper.findStartPosition(
            selectedText: "Goodbye world",
            hrefString: "ch1.xhtml",
            paragraphs: paragraphs
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.paragraphIndex, 1)
        XCTAssertEqual(result?.wordIndex, 2) // "Goodbye" has id 2
    }

    func testFindStartPositionDifferentResource() {
        let paragraphs = [
            BookParagraph(id: 0, text: "Hello world", words: makeWords(["Hello", "world"], startId: 0), chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml"),
            BookParagraph(id: 1, text: "Hello world", words: makeWords(["Hello", "world"], startId: 2), chapterIndex: 1, isHeading: false, resourceHref: "ch2.xhtml"),
        ]

        let result = TTSHighlightHelper.findStartPosition(
            selectedText: "Hello",
            hrefString: "ch2.xhtml",
            paragraphs: paragraphs
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.paragraphIndex, 1)
        XCTAssertEqual(result?.wordIndex, 2) // "Hello" in ch2 has id 2
    }

    func testFindStartPositionEmptySelection() {
        let paragraphs = [
            BookParagraph(id: 0, text: "Hello", words: makeWords(["Hello"], startId: 0), chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml"),
        ]

        let result = TTSHighlightHelper.findStartPosition(
            selectedText: "",
            hrefString: "ch1.xhtml",
            paragraphs: paragraphs
        )
        XCTAssertNil(result)
    }

    func testFindStartPositionEmptyWords() {
        let paragraphs = [
            BookParagraph(id: 0, text: "", words: [], chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml"),
        ]
        let result = TTSHighlightHelper.findStartPosition(
            selectedText: "Hello",
            hrefString: "ch1.xhtml",
            paragraphs: paragraphs
        )
        XCTAssertNil(result)
    }

    func testFindStartPositionMultiWordSelectionNoFallback() {
        // Multi-word selection that doesn't match any paragraph text should NOT
        // fall back to single-word matching (too ambiguous)
        let paragraphs = [
            BookParagraph(id: 0, text: "The cat sat", words: makeWords(["The", "cat", "sat"], startId: 0), chapterIndex: 0, isHeading: false, resourceHref: "ch1.xhtml"),
        ]
        let result = TTSHighlightHelper.findStartPosition(
            selectedText: "The dog ran",
            hrefString: "ch1.xhtml",
            paragraphs: paragraphs
        )
        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func makeWords(_ texts: [String], startId: Int = 0) -> [BookWord] {
        texts.enumerated().map { idx, text in
            BookWord(id: startId + idx, text: text, paragraphId: 0)
        }
    }
}
