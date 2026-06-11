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
}
