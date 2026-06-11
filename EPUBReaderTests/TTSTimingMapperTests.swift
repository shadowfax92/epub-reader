import XCTest
@testable import EPUBReader

final class TTSTimingMapperTests: XCTestCase {

    // MARK: - mapAlignment (run-based walk)

    func testExactWalkTwoWords() {
        let (chars, starts, ends) = makeAlignment("Hello world")
        let words = [BookWord(id: 10, text: "Hello", paragraphId: 0),
                     BookWord(id: 11, text: "world", paragraphId: 0)]

        let timings = TTSTimingMapper.mapAlignment(characters: chars, startTimes: starts, endTimes: ends, words: words)

        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].globalWordIndex, 10)
        XCTAssertEqual(timings[0].startTime, starts[0], accuracy: 0.0001)
        XCTAssertEqual(timings[0].endTime, ends[4], accuracy: 0.0001) // last char of "Hello"
        XCTAssertEqual(timings[1].globalWordIndex, 11)
        XCTAssertEqual(timings[1].startTime, starts[6], accuracy: 0.0001) // 'w'
        XCTAssertEqual(timings[1].endTime, ends[10], accuracy: 0.0001)
    }

    func testDoubleSpaceBetweenRunsStillPairs() {
        let (chars, starts, ends) = makeAlignment("Hi  there")
        let words = [BookWord(id: 0, text: "Hi", paragraphId: 0),
                     BookWord(id: 1, text: "there", paragraphId: 0)]

        let timings = TTSTimingMapper.mapAlignment(characters: chars, startTimes: starts, endTimes: ends, words: words)

        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].endTime, ends[1], accuracy: 0.0001)   // 'i' of "Hi"
        XCTAssertEqual(timings[1].startTime, starts[4], accuracy: 0.0001) // 't' after both spaces
    }

    func testMismatchedWordLengthsNoDriftWhenRunsPair() {
        // Book word "2022" (4 chars) vs spoken run "twenty" (6 chars): run-based
        // pairing must keep "rocks" anchored to its own run, not shifted by length math.
        let (chars, starts, ends) = makeAlignment("twenty rocks")
        let words = [BookWord(id: 3, text: "2022", paragraphId: 0),
                     BookWord(id: 4, text: "rocks", paragraphId: 0)]

        let timings = TTSTimingMapper.mapAlignment(characters: chars, startTimes: starts, endTimes: ends, words: words)

        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[1].globalWordIndex, 4)
        XCTAssertEqual(timings[1].startTime, starts[7], accuracy: 0.0001) // 'r' of "rocks"
        XCTAssertEqual(timings[1].endTime, ends[11], accuracy: 0.0001)
    }

    func testRunCountMismatchFallsBackToProportional() {
        // 3 spoken runs vs 2 book words (normalization expanded something):
        // fall back to proportional distribution across the alignment's span.
        let (chars, starts, ends) = makeAlignment("a b c")
        let words = [BookWord(id: 0, text: "ab", paragraphId: 0),
                     BookWord(id: 1, text: "c", paragraphId: 0)]

        let timings = TTSTimingMapper.mapAlignment(characters: chars, startTimes: starts, endTimes: ends, words: words)

        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].startTime, starts[0], accuracy: 0.0001)
        XCTAssertEqual(timings[1].endTime, ends[4], accuracy: 0.001)
        XCTAssertLessThanOrEqual(timings[0].endTime, timings[1].startTime + 0.0001)
        XCTAssertEqual(timings[0].globalWordIndex, 0)
        XCTAssertEqual(timings[1].globalWordIndex, 1)
    }

    func testEmptyInputsProduceNoTimings() {
        let words = [BookWord(id: 0, text: "Hi", paragraphId: 0)]
        XCTAssertTrue(TTSTimingMapper.mapAlignment(characters: [], startTimes: [], endTimes: [], words: words).isEmpty)

        let (chars, starts, ends) = makeAlignment("Hi")
        XCTAssertTrue(TTSTimingMapper.mapAlignment(characters: chars, startTimes: starts, endTimes: ends, words: []).isEmpty)
    }

    // MARK: - proportionalTimings

    func testProportionalEqualWordsSplitEvenly() {
        let words = [BookWord(id: 0, text: "aa", paragraphId: 0),
                     BookWord(id: 1, text: "bb", paragraphId: 0),
                     BookWord(id: 2, text: "cc", paragraphId: 0)]

        let timings = TTSTimingMapper.proportionalTimings(words: words, duration: 10.0)

        XCTAssertEqual(timings.count, 3)
        XCTAssertEqual(timings[0].startTime, 0.0, accuracy: 0.0001)
        XCTAssertEqual(timings[2].endTime, 10.0, accuracy: 0.001)
        XCTAssertLessThan(timings[0].startTime, timings[1].startTime)
        XCTAssertLessThan(timings[1].startTime, timings[2].startTime)
        // 2-char words + 1-char gaps = 8 units over 10s → each word spans 2.5s
        XCTAssertEqual(timings[0].endTime - timings[0].startTime, 2.5, accuracy: 0.001)
        XCTAssertEqual(timings[1].endTime - timings[1].startTime, 2.5, accuracy: 0.001)
    }

    func testProportionalDegenerateInputs() {
        let words = [BookWord(id: 0, text: "Hi", paragraphId: 0)]
        XCTAssertTrue(TTSTimingMapper.proportionalTimings(words: [], duration: 10.0).isEmpty)
        XCTAssertTrue(TTSTimingMapper.proportionalTimings(words: words, duration: 0).isEmpty)
    }

    // MARK: - currentWordIndex (binary search)

    func testCurrentWordIndexBoundaries() {
        let timings = [WordTiming(globalWordIndex: 5, startTime: 0.0, endTime: 0.4),
                       WordTiming(globalWordIndex: 6, startTime: 0.5, endTime: 0.9),
                       WordTiming(globalWordIndex: 7, startTime: 1.0, endTime: 1.4)]

        XCTAssertNil(TTSTimingMapper.currentWordIndex(timings: timings, at: -0.1))
        XCTAssertEqual(TTSTimingMapper.currentWordIndex(timings: timings, at: 0.0), 5)
        XCTAssertEqual(TTSTimingMapper.currentWordIndex(timings: timings, at: 0.45), 5) // gap → earlier word
        XCTAssertEqual(TTSTimingMapper.currentWordIndex(timings: timings, at: 0.5), 6)
        XCTAssertEqual(TTSTimingMapper.currentWordIndex(timings: timings, at: 0.7), 6)
        XCTAssertEqual(TTSTimingMapper.currentWordIndex(timings: timings, at: 99), 7)
    }

    func testCurrentWordIndexEmpty() {
        XCTAssertNil(TTSTimingMapper.currentWordIndex(timings: [], at: 0.5))
    }

    // MARK: - Helpers

    /// Splits text into per-character alignment arrays with each char spanning 0.1s.
    private func makeAlignment(_ text: String) -> ([String], [Double], [Double]) {
        let chars = text.map { String($0) }
        let starts = (0..<chars.count).map { Double($0) * 0.1 }
        let ends = (1...chars.count).map { Double($0) * 0.1 }
        return (chars, starts, ends)
    }
}
