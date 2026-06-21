import XCTest
@testable import EPUBReader

@MainActor
final class AudioPlaybackManagerTests: XCTestCase {

    private func makeParagraphs() -> [BookParagraph] {
        var wordId = 0
        return (0..<3).map { paraId in
            let words = (0..<4).map { _ in
                defer { wordId += 1 }
                return BookWord(id: wordId, text: "w\(wordId)", paragraphId: paraId)
            }
            return BookParagraph(
                id: paraId,
                text: words.map(\.text).joined(separator: " "),
                words: words,
                chapterIndex: paraId,
                isHeading: false,
                resourceHref: "page=\(paraId + 1)"
            )
        }
    }

    func testStopAfterRestoreDoesNotRegressPosition() {
        let manager = AudioPlaybackManager()
        var savedPositions: [ReadingPosition] = []

        manager.configure(provider: .openAI, apiKey: "", voiceId: "", speed: 1.0) { position in
            savedPositions.append(position)
        }
        manager.setBook(paragraphs: makeParagraphs())
        manager.restorePosition(paragraphArrayIndex: 2, paragraphId: 2, globalWordIndex: 9)

        manager.stop()

        let saved = savedPositions.last
        XCTAssertEqual(saved?.paragraphIndex, 2, "stop before playback must keep the restored paragraph")
        XCTAssertEqual(saved?.globalWordIndex, 9)
        XCTAssertEqual(manager.currentParagraphId, 2)
    }

    func testRestoreClampsOutOfRangeParagraphIndex() {
        let manager = AudioPlaybackManager()
        manager.setBook(paragraphs: makeParagraphs())
        manager.restorePosition(paragraphArrayIndex: 99, paragraphId: 2, globalWordIndex: 9)

        var savedPositions: [ReadingPosition] = []
        manager.configure(provider: .openAI, apiKey: "", voiceId: "", speed: 1.0) { position in
            savedPositions.append(position)
        }
        manager.stop()

        XCTAssertEqual(savedPositions.last?.paragraphIndex, 2)
    }

    func testPlayClearsStaleErrorImmediately() {
        let manager = AudioPlaybackManager()
        manager.setBook(paragraphs: makeParagraphs())
        manager.configure(provider: .openAI, apiKey: "", voiceId: "", speed: 1.0) { _ in }
        manager.error = "Previous selection failed."

        manager.play(fromParagraphIndex: 0)

        XCTAssertNil(manager.error)
        manager.stop()
    }
}
