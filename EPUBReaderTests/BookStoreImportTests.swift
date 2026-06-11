import XCTest
@testable import EPUBReader

@MainActor
final class BookStoreImportTests: XCTestCase {

    private var booksDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books")
    }

    private func booksDirContents() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? [])
    }

    // MARK: - EPUB

    func testImportsExplodedEPUBDirectory() async throws {
        let store = BookStore()
        let dir = try EPUBFixtures.explodedEPUB(named: "Import Me \(UUID().uuidString).epub")
        defer { EPUBFixtures.cleanup(dir) }

        let book = try await store.importBook(from: dir)
        defer { store.removeBook(book) }

        XCTAssertEqual(book.title, "Test Book")
        XCTAssertEqual(book.author, "Test Author")
        XCTAssertTrue(store.books.contains(book))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRejectsNonEPUBDirectoryWithoutCopying() async throws {
        let store = BookStore()
        let dir = try EPUBFixtures.nonEPUBDirectory()
        defer { EPUBFixtures.cleanup(dir) }
        let before = booksDirContents()

        do {
            _ = try await store.importBook(from: dir)
            XCTFail("Expected import to throw for a non-EPUB directory")
        } catch {
            // expected
        }

        XCTAssertEqual(booksDirContents(), before, "rejected folder must not be copied into Books/")
    }

    func testFailedParseLeavesNoOrphan() async throws {
        let store = BookStore()
        let dir = try EPUBFixtures.unparseableEPUB(named: "Orphan \(UUID().uuidString).epub")
        defer { EPUBFixtures.cleanup(dir) }
        let before = booksDirContents()

        do {
            _ = try await store.importBook(from: dir)
            XCTFail("Expected import to throw for a broken EPUB")
        } catch {
            // expected
        }

        XCTAssertEqual(booksDirContents(), before, "failed import must clean up the copied item")
    }

    func testCoordinatedCopyCopiesRegularFile() async throws {
        let dir = try EPUBFixtures.directory(files: ["sample.epub": "zipped-bytes-stand-in"])
        defer { EPUBFixtures.cleanup(dir) }
        let source = dir.appendingPathComponent("sample.epub")
        let destination = dir.appendingPathComponent("copy.epub")

        try await BookStore.coordinatedCopy(from: source, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "zipped-bytes-stand-in")
    }

    // MARK: - PDF

    func testImportRejectsPasswordProtectedPDFAndCleansUp() async throws {
        let url = try PDFTestFixtures.makePDF(pages: ["secret text"], password: "pw")
        let store = BookStore()
        let before = booksDirContents()

        do {
            _ = try await store.importBook(from: url)
            XCTFail("expected PDFError.passwordProtected")
        } catch let error as PDFError {
            XCTAssertEqual(error, .passwordProtected)
        }

        XCTAssertEqual(booksDirContents(), before, "rejected import must not land in Books/")
        XCTAssertFalse(store.books.contains { $0.fileName == url.lastPathComponent })
    }

    func testImportRejectsCorruptPDFAndCleansUp() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data("this is not a pdf".utf8).write(to: url)
        let store = BookStore()
        let before = booksDirContents()

        do {
            _ = try await store.importBook(from: url)
            XCTFail("expected PDFError.invalidFile")
        } catch let error as PDFError {
            XCTAssertEqual(error, .invalidFile)
        }

        XCTAssertEqual(booksDirContents(), before)
        XCTAssertFalse(store.books.contains { $0.fileName == url.lastPathComponent })
    }
}
