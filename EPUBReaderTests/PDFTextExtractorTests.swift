import XCTest
@testable import EPUBReader

final class PDFTextExtractorTests: XCTestCase {

    private func allTokens(_ blocks: [PDFTextExtractor.ParagraphBlock]) -> [PDFTextExtractor.Token] {
        blocks.flatMap(\.tokens)
    }

    // MARK: - Tokenization & ranges

    func testBasicTokenizationWithExactRanges() {
        let source = "Hello world"
        let blocks = PDFTextExtractor.paragraphs(from: source)

        XCTAssertEqual(blocks.count, 1)
        let tokens = blocks[0].tokens
        XCTAssertEqual(tokens.map(\.text), ["Hello", "world"])

        let ns = source as NSString
        for token in tokens {
            XCTAssertEqual(ns.substring(with: token.range), token.text)
        }
    }

    func testRangesAroundMultiByteCharacters() {
        let source = "“Quotes” and café — done 👍 yes"
        let blocks = PDFTextExtractor.paragraphs(from: source)
        let tokens = allTokens(blocks)

        XCTAssertEqual(tokens.map(\.text), ["“Quotes”", "and", "café", "—", "done", "👍", "yes"])

        let ns = source as NSString
        for token in tokens {
            XCTAssertEqual(ns.substring(with: token.range), token.text)
        }
    }

    func testLeadingAndTrailingWhitespaceTolerated() {
        let blocks = PDFTextExtractor.paragraphs(from: "  hello world \n")
        XCTAssertEqual(allTokens(blocks).map(\.text), ["hello", "world"])
    }

    // MARK: - Hyphenation

    func testHyphenAtLineBreakMergesIntoOneWord() {
        let source = "This is an exam-\nple of merging"
        let blocks = PDFTextExtractor.paragraphs(from: source)
        let tokens = allTokens(blocks)

        XCTAssertEqual(tokens.map(\.text), ["This", "is", "an", "example", "of", "merging"])

        let merged = tokens[3]
        XCTAssertEqual((source as NSString).substring(with: merged.range), "exam-\nple")
    }

    func testChainedHyphenLineBreaksMerge() {
        let source = "a multi-\nline-\nword here"
        let tokens = allTokens(PDFTextExtractor.paragraphs(from: source))
        XCTAssertEqual(tokens.map(\.text), ["a", "multilineword", "here"])
    }

    func testHyphenCompoundOnSameLineUnchanged() {
        let tokens = allTokens(PDFTextExtractor.paragraphs(from: "a well-known fact"))
        XCTAssertEqual(tokens.map(\.text), ["a", "well-known", "fact"])
    }

    func testHyphenFollowedBySpaceDoesNotMerge() {
        let tokens = allTokens(PDFTextExtractor.paragraphs(from: "ex- ample"))
        XCTAssertEqual(tokens.map(\.text), ["ex-", "ample"])
    }

    func testHyphenAcrossBlankLineDoesNotMerge() {
        let blocks = PDFTextExtractor.paragraphs(from: "ends with hyphen-\n\nnew paragraph")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].tokens.last?.text, "hyphen-")
        XCTAssertEqual(blocks[1].tokens.first?.text, "new")
    }

    // MARK: - Paragraph segmentation

    func testBlankLineStartsNewParagraph() {
        let blocks = PDFTextExtractor.paragraphs(from: "Para one.\n\nPara two.")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].tokens.map(\.text), ["Para", "one."])
        XCTAssertEqual(blocks[1].tokens.map(\.text), ["Para", "two."])
    }

    func testSingleNewlineDoesNotSplitParagraph() {
        let blocks = PDFTextExtractor.paragraphs(from: "line one\nline two")
        XCTAssertEqual(blocks.count, 1)
    }

    func testCRLFLineEndingsCountAsSingleBreaks() {
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: "line one\r\nline two").count, 1)
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: "p1\r\n\r\np2").count, 2)
    }

    func testUnicodeLineBreaksCountAsBreaks() {
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: "a\u{85}b").count, 1)
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: "p1\u{85}\u{85}p2").count, 2)
        XCTAssertEqual(PDFTextExtractor.paragraphs(from: "p1\u{0C}\u{0C}p2").count, 2)
        // Hyphen merge works across a NEL like a plain newline.
        let tokens = allTokens(PDFTextExtractor.paragraphs(from: "exam-\u{85}ple"))
        XCTAssertEqual(tokens.map(\.text), ["example"])
    }

    // MARK: - Word caps

    func testLongRunSplitsAtSentenceBoundaryAfterSoftCap() {
        // Sentence ends at words 95 and 110; soft cap is 100, so the split must land at 110.
        let words = (1...120).map { i -> String in
            if i == 95 || i == 110 { return "w\(i)." }
            return "w\(i)"
        }
        let blocks = PDFTextExtractor.paragraphs(from: words.joined(separator: " "))
        XCTAssertEqual(blocks.map(\.tokens.count), [110, 10])
    }

    func testLongRunWithoutSentenceBoundaryHardSplits() {
        let words = (1...200).map { "w\($0)" }
        let blocks = PDFTextExtractor.paragraphs(from: words.joined(separator: " "))
        XCTAssertEqual(blocks.map(\.tokens.count), [150, 50])
    }

    func testSentenceEndRecognizedThroughClosingQuote() {
        let words = (1...105).map { i -> String in
            if i == 102 { return "done.”" }
            return "w\(i)"
        }
        let blocks = PDFTextExtractor.paragraphs(from: words.joined(separator: " "))
        XCTAssertEqual(blocks.map(\.tokens.count), [102, 3])
    }

    // MARK: - Empty input

    func testEmptyAndWhitespaceOnlyInputs() {
        XCTAssertTrue(PDFTextExtractor.paragraphs(from: "").isEmpty)
        XCTAssertTrue(PDFTextExtractor.paragraphs(from: "  \n\n \t ").isEmpty)
    }
}
