import XCTest
import UniformTypeIdentifiers
@testable import EPUBReader

private struct StubError: Error {}

@MainActor
final class BookDropImportTests: XCTestCase {

    // MARK: - acceptedTypes

    func testAcceptedTypesCoverFileURLsAndBookTypes() {
        let types = BookDropImport.acceptedTypes
        XCTAssertTrue(types.contains(.fileURL))
        XCTAssertTrue(types.contains(.epub))
        XCTAssertTrue(types.contains(.pdf))
        XCTAssertTrue(types.contains(.folder))
        XCTAssertTrue(types.contains(.package))
    }

    // MARK: - In-place resolution

    func testReadableFileURLResolvesInPlace() async throws {
        let dir = try EPUBFixtures.directory(files: ["book.epub": "epub-bytes"])
        defer { EPUBFixtures.cleanup(dir) }
        let fileURL = dir.appendingPathComponent("book.epub")

        let item = try await BookDropImport.resolveItem(from: Self.fileURLProvider(for: fileURL))
        XCTAssertEqual(item.url.standardizedFileURL.path, fileURL.standardizedFileURL.path)
        XCTAssertNil(item.ownedTemporaryDirectory)
        // needsSecurityScopeRelease is OS-determined for in-place URLs (iOS
        // reports true even inside the app's own container), so no assertion.
    }

    func testExplodedEPUBDirectoryURLResolvesInPlace() async throws {
        let dir = try EPUBFixtures.directory(files: ["mimetype": "application/epub+zip"])
        defer { EPUBFixtures.cleanup(dir) }

        let item = try await BookDropImport.resolveItem(from: Self.fileURLProvider(for: dir))
        XCTAssertEqual(item.url.standardizedFileURL.path, dir.standardizedFileURL.path)
        XCTAssertNil(item.ownedTemporaryDirectory)
    }

    // MARK: - Copy fallback

    func testFileRepresentationOnlyProviderResolvesToOwnedCopy() async throws {
        let dir = try EPUBFixtures.directory(files: ["book.epub": "epub-bytes"])
        defer { EPUBFixtures.cleanup(dir) }
        let fileURL = dir.appendingPathComponent("book.epub")

        let provider = NSItemProvider()
        Self.registerFileRepresentation(on: provider, type: .epub, url: fileURL)

        let item = try await BookDropImport.resolveItem(from: provider)
        defer { item.ownedTemporaryDirectory.map { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertNotNil(item.ownedTemporaryDirectory)
        XCTAssertNotEqual(item.url.standardizedFileURL.path, fileURL.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "epub-bytes")
        XCTAssertFalse(item.needsSecurityScopeRelease)
    }

    func testCopyFailureWrapsErrorAndCleansStagingDirectory() async throws {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.epub.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(nil, false, StubError())
            return nil
        }

        let stagingDirsBefore = Self.dropStagingDirectories()
        do {
            _ = try await BookDropImport.resolveItem(from: provider)
            XCTFail("Expected DropError.copyFailed")
        } catch let error as BookDropImport.DropError {
            guard case .copyFailed = error else {
                return XCTFail("Expected copyFailed, got \(error)")
            }
        }
        XCTAssertEqual(Self.dropStagingDirectories(), stagingDirsBefore, "failed copy must not leak staging dirs")
    }

    func testFileURLLoadFailureWithoutFallbackThrowsLoadFailed() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(nil, StubError())
            return nil
        }

        do {
            _ = try await BookDropImport.resolveItem(from: provider)
            XCTFail("Expected DropError.loadFailed")
        } catch let error as BookDropImport.DropError {
            guard case .loadFailed = error else {
                return XCTFail("Expected loadFailed, got \(error)")
            }
        }
    }

    func testUnreadableFileURLWithoutFallbackThrowsLoadFailed() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookDropImportTests-missing-\(UUID().uuidString).epub")

        do {
            _ = try await BookDropImport.resolveItem(from: Self.fileURLProvider(for: missing))
            XCTFail("Expected DropError.loadFailed")
        } catch let error as BookDropImport.DropError {
            guard case .loadFailed = error else {
                return XCTFail("Expected loadFailed, got \(error)")
            }
        }
    }

    func testUnreadableFileURLFallsBackToCopy() async throws {
        let dir = try EPUBFixtures.directory(files: ["book.epub": "epub-bytes"])
        defer { EPUBFixtures.cleanup(dir) }
        let fileURL = dir.appendingPathComponent("book.epub")
        let missing = dir.appendingPathComponent("missing.epub")

        let provider = Self.fileURLProvider(for: missing)
        Self.registerFileRepresentation(on: provider, type: .epub, url: fileURL)

        let item = try await BookDropImport.resolveItem(from: provider)
        defer { item.ownedTemporaryDirectory.map { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertNotNil(item.ownedTemporaryDirectory)
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "epub-bytes")
    }

    // MARK: - Unsupported content

    func testProviderWithoutImportableContentThrows() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data("hello".utf8), nil)
            return nil
        }

        do {
            _ = try await BookDropImport.resolveItem(from: provider)
            XCTFail("Expected DropError.noImportableContent")
        } catch let error as BookDropImport.DropError {
            guard case .noImportableContent = error else {
                return XCTFail("Expected noImportableContent, got \(error)")
            }
        }
    }

    // MARK: - copyableTypeIdentifier

    func testCopyableTypeIdentifierPrefersFirstBookType() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.epub.identifier,
            visibility: .all
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        XCTAssertEqual(BookDropImport.copyableTypeIdentifier(for: provider), UTType.epub.identifier)
    }

    func testCopyableTypeIdentifierIgnoresFileURLType() {
        let provider = Self.fileURLProvider(for: URL(fileURLWithPath: "/tmp/x.epub"))
        XCTAssertNil(BookDropImport.copyableTypeIdentifier(for: provider))
    }

    // MARK: - Provider helpers

    private static func dropStagingDirectories() -> Set<String> {
        let tmp = FileManager.default.temporaryDirectory.path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        return Set(entries.filter { $0.hasPrefix(BookDropImport.stagingPrefix) })
    }

    /// Provider registering only `public.file-url` bytes, like a Finder drag.
    private static func fileURLProvider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = url.dataRepresentation
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private static func registerFileRepresentation(on provider: NSItemProvider, type: UTType, url: URL) {
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, false, nil)
            return nil
        }
    }
}
