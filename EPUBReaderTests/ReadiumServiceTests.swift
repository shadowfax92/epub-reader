import XCTest
@testable import EPUBReader

@MainActor
final class ReadiumServiceTests: XCTestCase {

    func testOpensExplodedEPUBDirectory() async throws {
        let dir = try EPUBFixtures.explodedEPUB(named: "Essays.epub")
        defer { EPUBFixtures.cleanup(dir) }

        let publication = try await ReadiumService.shared.openPublication(at: dir)

        XCTAssertEqual(publication.metadata.title, "Test Book")
        XCTAssertEqual(publication.metadata.authors.first?.name, "Test Author")
        XCTAssertFalse(publication.readingOrder.isEmpty)
    }

    func testThrowsForNonEPUBDirectory() async throws {
        let dir = try EPUBFixtures.nonEPUBDirectory()
        defer { EPUBFixtures.cleanup(dir) }

        do {
            _ = try await ReadiumService.shared.openPublication(at: dir)
            XCTFail("Expected openPublication to throw for a non-EPUB directory")
        } catch {
            // expected
        }
    }
}
