import XCTest
@testable import EPUBReader

final class BookFormatTests: XCTestCase {

    func testPDFExtensionDetected() {
        XCTAssertEqual(BookFormat(fileName: "report.pdf"), .pdf)
        XCTAssertEqual(BookFormat(fileName: "Report.PDF"), .pdf)
    }

    func testNonPDFDefaultsToEPUB() {
        XCTAssertEqual(BookFormat(fileName: "book.epub"), .epub)
        XCTAssertEqual(BookFormat(fileName: "strange.txt"), .epub)
        XCTAssertEqual(BookFormat(fileName: "noext"), .epub)
    }

    func testMetadataFormat() {
        let pdf = BookMetadata(id: UUID(), title: "T", author: "A", fileName: "doc.pdf", dateAdded: Date())
        XCTAssertEqual(pdf.format, .pdf)

        let epub = BookMetadata(id: UUID(), title: "T", author: "A", fileName: "doc.epub", dateAdded: Date())
        XCTAssertEqual(epub.format, .epub)
    }

    func testFallbackTitleStripsAnyExtension() {
        XCTAssertEqual(BookMetadata.fallbackTitle(forFileName: "My Paper.pdf"), "My Paper")
        XCTAssertEqual(BookMetadata.fallbackTitle(forFileName: "book.epub"), "book")
        XCTAssertEqual(BookMetadata.fallbackTitle(forFileName: "noext"), "noext")
    }
}
