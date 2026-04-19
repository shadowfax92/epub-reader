import XCTest
@testable import EPUBReader

final class ReadingStateRecordTests: XCTestCase {
    func testNewestPrefersRemoteWhenTimestampIsNewer() {
        let local = ReadingStateRecord(
            position: ReadingPosition(chapterIndex: 1, paragraphIndex: 2, globalWordIndex: 3),
            locatorJSON: "{\"href\":\"a\"}",
            updatedAt: 100
        )
        let remote = ReadingStateRecord(
            position: ReadingPosition(chapterIndex: 4, paragraphIndex: 5, globalWordIndex: 6),
            locatorJSON: "{\"href\":\"b\"}",
            updatedAt: 200
        )

        let newest = ReadingStateRecord.newest(local: local, remote: remote)

        XCTAssertEqual(newest, remote)
    }

    func testNewestPrefersLocalWhenRemoteMissing() {
        let local = ReadingStateRecord(
            position: ReadingPosition(chapterIndex: 1, paragraphIndex: 2, globalWordIndex: 3),
            locatorJSON: "{\"href\":\"a\"}",
            updatedAt: 100
        )

        let newest = ReadingStateRecord.newest(local: local, remote: nil)

        XCTAssertEqual(newest, local)
    }

    func testNewestBreaksTiesInFavorOfRemote() {
        let local = ReadingStateRecord(
            position: ReadingPosition(chapterIndex: 1, paragraphIndex: 2, globalWordIndex: 3),
            locatorJSON: "{\"href\":\"a\"}",
            updatedAt: 100
        )
        let remote = ReadingStateRecord(
            position: ReadingPosition(chapterIndex: 4, paragraphIndex: 5, globalWordIndex: 6),
            locatorJSON: "{\"href\":\"b\"}",
            updatedAt: 100
        )

        let newest = ReadingStateRecord.newest(local: local, remote: remote)

        XCTAssertEqual(newest, remote)
    }
}
