import XCTest
@testable import EPUBReader

/// Covers the BookStore wiring behind the Library "percent read" indicator:
/// format dispatch in `progressFraction`, the PDF page-count cache, the off-main
/// page-count load, and cache cleanup on removal. The pure math lives in
/// `ReadingProgressTests`.
@MainActor
final class BookStoreProgressTests: XCTestCase {
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for suiteName in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    // MARK: - EPUB

    func testEPUBProgressFractionComesFromStoredLocator() async throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let book = makeBook(fileName: "novel.epub")
        defaults.set(epubLocatorJSON(totalProgression: 0.5), forKey: "locator_\(book.id.uuidString)")

        let fraction = await store.progressFraction(for: book)
        XCTAssertEqual(try XCTUnwrap(fraction), 0.5, accuracy: 0.0001)
    }

    func testEPUBProgressFractionNilWithoutLocator() async {
        let store = makeStore(defaults: makeDefaults())
        let fraction = await store.progressFraction(for: makeBook(fileName: "fresh.epub"))
        XCTAssertNil(fraction)
    }

    // MARK: - PDF

    func testPDFProgressFractionUsesCachedPageCountWithoutLoadingFile() async throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        // Point at a file that does not exist: a cache hit must not need to read it.
        let book = makeBook(fileName: "missing-\(UUID().uuidString).pdf")
        defaults.set(4, forKey: "pdfPage_\(book.id.uuidString)")
        defaults.set(10, forKey: "pdfPageCount_\(book.id.uuidString)")

        let fraction = await store.progressFraction(for: book)
        XCTAssertEqual(try XCTUnwrap(fraction), 0.5, accuracy: 0.0001)
    }

    func testPDFProgressFractionNilWithoutSavedPage() async {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let book = makeBook(fileName: "untouched.pdf")
        defaults.set(10, forKey: "pdfPageCount_\(book.id.uuidString)")

        let fraction = await store.progressFraction(for: book)
        XCTAssertNil(fraction)
    }

    func testProgressFractionLoadsAndCachesRealPDFPageCount() async throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let url = try PDFTestFixtures.makePDF(pages: ["one", "two", "three", "four"])
        defer { try? FileManager.default.removeItem(at: url) }
        // Place a book whose fileURL resolves to the generated PDF.
        let book = makeBook(fileName: url.lastPathComponent)
        try FileManager.default.createDirectory(at: book.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: book.fileURL)
        defer { try? FileManager.default.removeItem(at: book.fileURL) }
        defaults.set(1, forKey: "pdfPage_\(book.id.uuidString)") // page 2 of 4

        let fraction = await store.progressFraction(for: book)
        XCTAssertEqual(try XCTUnwrap(fraction), 0.5, accuracy: 0.0001)
        // The load must have populated the cache for next time.
        XCTAssertEqual(defaults.object(forKey: "pdfPageCount_\(book.id.uuidString)") as? Int, 4)
    }

    func testLoadPDFPageCountReadsRealDocumentAndNilForNonPDF() async throws {
        let url = try PDFTestFixtures.makePDF(pages: ["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: url) }
        let count = await BookStore.loadPDFPageCount(at: url)
        XCTAssertEqual(count, 3)

        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")
        let none = await BookStore.loadPDFPageCount(at: missing)
        XCTAssertNil(none)
    }

    func testRemoveBookClearsCachedPDFPageCount() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let book = makeBook(fileName: "remove-me.pdf")
        store.books = [book]
        defaults.set(2, forKey: "pdfPage_\(book.id.uuidString)")
        defaults.set(50, forKey: "pdfPageCount_\(book.id.uuidString)")

        store.removeBook(book)

        XCTAssertNil(defaults.object(forKey: "pdfPageCount_\(book.id.uuidString)"))
        XCTAssertNil(defaults.object(forKey: "pdfPage_\(book.id.uuidString)"))
    }

    // MARK: - Helpers

    private func makeStore(defaults: UserDefaults) -> BookStore {
        BookStore(
            defaults: defaults,
            cloudProgressStore: CloudReadingProgressStore(store: FakeCloudKeyValueStore(), notificationObject: nil),
            notificationCenter: NotificationCenter()
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "BookStoreProgressTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeBook(fileName: String) -> BookMetadata {
        BookMetadata(id: UUID(), title: "T", author: "A", fileName: fileName, dateAdded: Date(timeIntervalSince1970: 0))
    }

    private func epubLocatorJSON(totalProgression: Double) -> String {
        "{\"href\":\"chapter1.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"totalProgression\":\(totalProgression)}}"
    }
}

private final class FakeCloudKeyValueStore: CloudReadingProgressKeyValueStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() -> Bool { true }
}
