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

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "autoAdvancePagesWithSpeech")
        UserDefaults.standard.removeObject(forKey: "autoAdvancePagesWithSpeechInPDF")
        super.tearDown()
    }

    // MARK: - Settings

    func testAutoAdvancePagesWithSpeechDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: "autoAdvancePagesWithSpeech")
        let store = BookStore()

        XCTAssertTrue(store.autoAdvancePagesWithSpeech)
    }

    func testAutoAdvancePagesWithSpeechPersistsFalse() {
        let store = BookStore()
        store.autoAdvancePagesWithSpeech = false

        let reloaded = BookStore()

        XCTAssertFalse(reloaded.autoAdvancePagesWithSpeech)
    }

    func testAutoAdvancePagesWithSpeechInPDFDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: "autoAdvancePagesWithSpeechInPDF")
        let store = BookStore()

        XCTAssertTrue(store.autoAdvancePagesWithSpeechInPDF)
    }

    func testAutoAdvancePagesWithSpeechInPDFPersistsFalseIndependently() {
        let store = BookStore()
        store.autoAdvancePagesWithSpeech = true
        store.autoAdvancePagesWithSpeechInPDF = false

        let reloaded = BookStore()

        XCTAssertFalse(reloaded.autoAdvancePagesWithSpeechInPDF)
        // The EPUB toggle is independent and unaffected.
        XCTAssertTrue(reloaded.autoAdvancePagesWithSpeech)
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
        XCTAssertNotNil(book.contentFingerprint)
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

    func testSameNamedImportsGetDistinctFiles() async throws {
        let store = BookStore()
        let name = "Same Name \(UUID().uuidString).epub"
        let dirA = try EPUBFixtures.explodedEPUB(named: name)
        let dirB = try EPUBFixtures.explodedEPUB(named: name)
        defer {
            EPUBFixtures.cleanup(dirA)
            EPUBFixtures.cleanup(dirB)
        }

        let a = try await store.importBook(from: dirA)
        let b = try await store.importBook(from: dirB)
        defer {
            store.removeBook(a)
            store.removeBook(b)
        }

        XCTAssertNotEqual(a.fileName, b.fileName, "same-named imports must not share a stored file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.fileURL.path))

        store.removeBook(a)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: b.fileURL.path),
            "deleting one entry must not remove the other's file"
        )
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

    func testImportStoresContentFingerprint() async throws {
        let url = try PDFTestFixtures.makePDF(pages: ["fingerprinted text"], title: "Fingerprint", author: "A")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BookStore()

        let book = try await store.importBook(from: url)
        defer { store.removeBook(book) }

        XCTAssertEqual(book.contentFingerprint, try BookStore.contentFingerprint(for: book.fileURL))
    }

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
