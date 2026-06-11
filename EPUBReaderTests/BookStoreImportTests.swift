import XCTest
@testable import EPUBReader

@MainActor
final class BookStoreImportTests: XCTestCase {

    private func copiedFileURL(for sourceURL: URL) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books")
            .appendingPathComponent(sourceURL.lastPathComponent)
    }

    func testImportRejectsPasswordProtectedPDFAndCleansUp() async throws {
        let url = try PDFTestFixtures.makePDF(pages: ["secret text"], password: "pw")
        let store = BookStore()
        let countBefore = store.books.count

        do {
            _ = try await store.importBook(from: url)
            XCTFail("expected PDFError.passwordProtected")
        } catch let error as PDFError {
            XCTAssertEqual(error, .passwordProtected)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedFileURL(for: url).path),
                       "rejected import must remove the copied file")
        XCTAssertEqual(store.books.count, countBefore)
    }

    func testImportRejectsCorruptPDFAndCleansUp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data("this is not a pdf".utf8).write(to: url)
        let store = BookStore()
        let countBefore = store.books.count

        do {
            _ = try await store.importBook(from: url)
            XCTFail("expected PDFError.invalidFile")
        } catch let error as PDFError {
            XCTAssertEqual(error, .invalidFile)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedFileURL(for: url).path))
        XCTAssertEqual(store.books.count, countBefore)
    }
}
