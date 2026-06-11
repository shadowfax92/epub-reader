import XCTest
import UniformTypeIdentifiers
@testable import EPUBReader

final class EPUBImportTests: XCTestCase {

    // MARK: - allowedContentTypes

    func testAllowedContentTypesIncludeEPUBAndFolder() {
        XCTAssertTrue(EPUBImport.allowedContentTypes.contains(.epub))
        XCTAssertTrue(EPUBImport.allowedContentTypes.contains(.folder))
    }

    // MARK: - isExplodedEPUBDirectory: valid cases

    func testFullExplodedEPUBIsValid() throws {
        let dir = try EPUBFixtures.explodedEPUB()
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertTrue(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testMimetypeOnlyDirectoryIsValid() throws {
        let dir = try EPUBFixtures.directory(files: ["mimetype": "application/epub+zip"])
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertTrue(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testContainerXMLOnlyDirectoryIsValid() throws {
        let dir = try EPUBFixtures.directory(files: ["META-INF/container.xml": "<container/>"])
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertTrue(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testMimetypeWithTrailingNewlineIsValid() throws {
        let dir = try EPUBFixtures.directory(files: ["mimetype": "application/epub+zip\n"])
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertTrue(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testUndownloadedContainerXMLPlaceholderIsValid() throws {
        let dir = try EPUBFixtures.directory(files: ["META-INF/.container.xml.icloud": "placeholder"])
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertTrue(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testUndownloadedMimetypePlaceholderIsValid() throws {
        let dir = try EPUBFixtures.directory(files: [".mimetype.icloud": "placeholder"])
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertTrue(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    // MARK: - isExplodedEPUBDirectory: invalid cases

    func testNonEPUBDirectoryIsInvalid() throws {
        let dir = try EPUBFixtures.nonEPUBDirectory()
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertFalse(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testWrongMimetypeWithoutContainerXMLIsInvalid() throws {
        let dir = try EPUBFixtures.directory(files: ["mimetype": "application/zip"])
        defer { EPUBFixtures.cleanup(dir) }
        XCTAssertFalse(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testRegularFileIsInvalid() throws {
        let dir = try EPUBFixtures.directory(files: ["book.epub": "not a real epub"])
        defer { EPUBFixtures.cleanup(dir) }
        let file = dir.appendingPathComponent("book.epub")
        XCTAssertFalse(EPUBImport.isExplodedEPUBDirectory(file))
    }

    func testUndecodableMimetypeWithoutContainerXMLIsInvalid() throws {
        let dir = try EPUBFixtures.directory(files: [:])
        defer { EPUBFixtures.cleanup(dir) }
        try Data([0xFF, 0xFE, 0xFA]).write(to: dir.appendingPathComponent("mimetype"))
        XCTAssertFalse(EPUBImport.isExplodedEPUBDirectory(dir))
    }

    func testNonexistentPathIsInvalid() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBImportTests-missing-\(UUID().uuidString)")
        XCTAssertFalse(EPUBImport.isExplodedEPUBDirectory(missing))
    }
}
