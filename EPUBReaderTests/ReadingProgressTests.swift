import XCTest
@testable import EPUBReader

final class ReadingProgressTests: XCTestCase {

    // MARK: - EPUB

    /// Builds a minimal valid Readium locator JSON (href + type are required to decode).
    private func epubLocatorJSON(totalProgression: Double?, progression: Double? = nil) -> String {
        var locations: [String] = []
        if let progression { locations.append("\"progression\":\(progression)") }
        if let totalProgression { locations.append("\"totalProgression\":\(totalProgression)") }
        let locationsJSON = "{\(locations.joined(separator: ","))}"
        return "{\"href\":\"chapter1.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":\(locationsJSON)}"
    }

    func testEPUBUsesTotalProgression() throws {
        let f = try XCTUnwrap(ReadingProgress.fraction(epubLocatorJSON: epubLocatorJSON(totalProgression: 0.42, progression: 0.9)))
        XCTAssertEqual(f, 0.42, accuracy: 0.0001)
    }

    func testEPUBWithoutTotalProgressionReturnsNil() {
        // Only chapter-relative progression present — must NOT fall back to it.
        XCTAssertNil(ReadingProgress.fraction(epubLocatorJSON: epubLocatorJSON(totalProgression: nil, progression: 0.5)))
    }

    func testEPUBNilEmptyOrMalformedReturnsNil() {
        XCTAssertNil(ReadingProgress.fraction(epubLocatorJSON: nil))
        XCTAssertNil(ReadingProgress.fraction(epubLocatorJSON: ""))
        XCTAssertNil(ReadingProgress.fraction(epubLocatorJSON: "not json"))
        // Valid JSON but missing the required href/type → Locator fails to decode.
        XCTAssertNil(ReadingProgress.fraction(epubLocatorJSON: "{\"locations\":{\"totalProgression\":0.5}}"))
    }

    func testEPUBClampsOutOfRange() throws {
        let high = try XCTUnwrap(ReadingProgress.fraction(epubLocatorJSON: epubLocatorJSON(totalProgression: 1.3)))
        XCTAssertEqual(high, 1.0, accuracy: 0.0001)
        let low = try XCTUnwrap(ReadingProgress.fraction(epubLocatorJSON: epubLocatorJSON(totalProgression: -0.1)))
        XCTAssertEqual(low, 0.0, accuracy: 0.0001)
    }

    // MARK: - PDF

    func testPDFFractionIsPageReachedOverTotal() throws {
        XCTAssertEqual(try XCTUnwrap(ReadingProgress.fraction(pdfPageIndex: 0, pageCount: 10)), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ReadingProgress.fraction(pdfPageIndex: 4, pageCount: 10)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ReadingProgress.fraction(pdfPageIndex: 9, pageCount: 10)), 1.0, accuracy: 0.0001)
        // Single-page document: being on it means done.
        XCTAssertEqual(try XCTUnwrap(ReadingProgress.fraction(pdfPageIndex: 0, pageCount: 1)), 1.0, accuracy: 0.0001)
    }

    func testPDFFractionNilForMissingOrInvalidInputs() {
        XCTAssertNil(ReadingProgress.fraction(pdfPageIndex: nil, pageCount: 10))
        XCTAssertNil(ReadingProgress.fraction(pdfPageIndex: 3, pageCount: nil))
        XCTAssertNil(ReadingProgress.fraction(pdfPageIndex: 3, pageCount: 0))
        XCTAssertNil(ReadingProgress.fraction(pdfPageIndex: 3, pageCount: -5))
    }

    // MARK: - percent

    func testPercentRoundsAndClamps() {
        XCTAssertNil(ReadingProgress.percent(nil))
        XCTAssertEqual(ReadingProgress.percent(0.0), 0)
        XCTAssertEqual(ReadingProgress.percent(0.426), 43)
        XCTAssertEqual(ReadingProgress.percent(0.5), 50)
        XCTAssertEqual(ReadingProgress.percent(1.0), 100)
        XCTAssertEqual(ReadingProgress.percent(1.3), 100)
        XCTAssertEqual(ReadingProgress.percent(-0.2), 0)
    }
}
