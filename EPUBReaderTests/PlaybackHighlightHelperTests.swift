import XCTest
@testable import EPUBReader

final class PlaybackHighlightHelperTests: XCTestCase {
    func testTimingIndexAdvancesFromPreviousIndex() {
        let timings = [
            PlaybackHighlightTiming(globalWordIndex: 0, startTime: 0.0, endTime: 0.2),
            PlaybackHighlightTiming(globalWordIndex: 1, startTime: 0.2, endTime: 0.4),
            PlaybackHighlightTiming(globalWordIndex: 2, startTime: 0.4, endTime: 0.6),
        ]

        let index = PlaybackHighlightHelper.timingIndex(
            for: 0.45,
            timings: timings,
            previousIndex: 1
        )

        XCTAssertEqual(index, 2)
    }

    func testTimingIndexMovesBackwardWhenScrubbingBack() {
        let timings = [
            PlaybackHighlightTiming(globalWordIndex: 0, startTime: 0.0, endTime: 0.2),
            PlaybackHighlightTiming(globalWordIndex: 1, startTime: 0.2, endTime: 0.4),
            PlaybackHighlightTiming(globalWordIndex: 2, startTime: 0.4, endTime: 0.6),
        ]

        let index = PlaybackHighlightHelper.timingIndex(
            for: 0.05,
            timings: timings,
            previousIndex: 2
        )

        XCTAssertEqual(index, 0)
    }

    func testShouldPublishHighlightRequiresMinimumInterval() {
        let shouldPublish = PlaybackHighlightHelper.shouldPublishHighlight(
            resolvedWordIndex: 11,
            displayedWordIndex: 10,
            currentTime: 0.24,
            lastPublishedTime: 0.20,
            minimumInterval: 0.10,
            isLastWord: false
        )

        XCTAssertFalse(shouldPublish)
    }

    func testShouldPublishHighlightAlwaysPublishesLastWord() {
        let shouldPublish = PlaybackHighlightHelper.shouldPublishHighlight(
            resolvedWordIndex: 12,
            displayedWordIndex: 11,
            currentTime: 0.24,
            lastPublishedTime: 0.20,
            minimumInterval: 0.10,
            isLastWord: true
        )

        XCTAssertTrue(shouldPublish)
    }
}
