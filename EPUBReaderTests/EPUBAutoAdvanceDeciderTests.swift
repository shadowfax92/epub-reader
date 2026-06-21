import XCTest
@testable import EPUBReader

final class EPUBAutoAdvanceDeciderTests: XCTestCase {

    func testDecisionDisabledResetsLastTarget() {
        let target = autoAdvanceTarget(position: 2, progression: 0.2)

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: nil,
            lastTarget: target,
            isEnabled: false,
            isPlaying: true
        )

        XCTAssertFalse(decision.shouldAdvance)
        XCTAssertNil(decision.nextLastTarget)
    }

    func testDecisionRequiresPlayback() {
        let target = autoAdvanceTarget(position: 2, progression: 0.2)

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: nil,
            lastTarget: target,
            isEnabled: true,
            isPlaying: false
        )

        XCTAssertFalse(decision.shouldAdvance)
        XCTAssertNil(decision.nextLastTarget)
    }

    func testDecisionAdvancesForNewHiddenTarget() {
        let target = autoAdvanceTarget(resourceHref: "Text/ch2.xhtml", position: 4, progression: 0.6)
        let previous = autoAdvanceTarget(resourceHref: "Text/ch1.xhtml", position: 1, progression: 0.1)

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: visibleTarget(resourceHrefs: ["Text/ch1.xhtml"], positions: 1...2),
            lastTarget: previous,
            isEnabled: true,
            isPlaying: true
        )

        XCTAssertTrue(decision.shouldAdvance)
        XCTAssertEqual(decision.nextLastTarget, target)
    }

    func testDecisionSuppressesTargetInsideVisiblePositionRange() {
        let target = autoAdvanceTarget(resourceHref: "OEBPS/Text/ch1.xhtml", position: 3)
        let visible = visibleTarget(resourceHrefs: ["Text/ch1.xhtml"], positions: 2...4)

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: visible,
            lastTarget: nil,
            isEnabled: true,
            isPlaying: true
        )

        XCTAssertFalse(decision.shouldAdvance)
        XCTAssertEqual(decision.nextLastTarget, target)
    }

    func testDecisionSuppressesTargetInsideVisibleProgressionRange() {
        let target = autoAdvanceTarget(resourceHref: "OEBPS/Text/ch1.xhtml", position: 3, progression: 0.45)
        let visible = visibleTarget(
            resourceHrefs: ["Text/ch1.xhtml"],
            positions: nil,
            progressions: ["Text/ch1.xhtml": 0.4...0.5]
        )

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: visible,
            lastTarget: nil,
            isEnabled: true,
            isPlaying: true
        )

        XCTAssertFalse(decision.shouldAdvance)
        XCTAssertEqual(decision.nextLastTarget, target)
    }

    func testDecisionAdvancesWhenSamePositionIsOutsideVisibleProgressionRange() {
        let target = autoAdvanceTarget(resourceHref: "Text/ch1.xhtml", position: 3, progression: 0.75)
        let visible = visibleTarget(
            resourceHrefs: ["Text/ch1.xhtml"],
            positions: 3...3,
            progressions: ["Text/ch1.xhtml": 0.4...0.5]
        )

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: visible,
            lastTarget: nil,
            isEnabled: true,
            isPlaying: true
        )

        XCTAssertTrue(decision.shouldAdvance)
        XCTAssertEqual(decision.nextLastTarget, target)
    }

    func testDecisionSuppressesRepeatedTarget() {
        let target = autoAdvanceTarget(position: 3, progression: 0.3)

        let decision = EPUBAutoAdvanceDecider.decide(
            target: target,
            visibleTarget: nil,
            lastTarget: target,
            isEnabled: true,
            isPlaying: true
        )

        XCTAssertFalse(decision.shouldAdvance)
        XCTAssertEqual(decision.nextLastTarget, target)
    }

    func testTargetEstimatesReadiumPositionAndProgressionFromWordProgress() {
        let paragraph = paragraph(id: 7, resourceHref: "Text/ch1.xhtml", wordIds: Array(100...109))
        let target = EPUBAutoAdvanceDecider.target(
            for: paragraph,
            wordIndex: 104,
            positionsByResourceHref: ["Text/ch1.xhtml": [10, 20, 30]],
            wordRangesByResourceHref: ["Text/ch1.xhtml": EPUBResourceWordRange(firstWordId: 100, lastWordId: 109)]
        )

        XCTAssertEqual(target.position, 20)
        XCTAssertEqual(target.progression ?? -1, 4.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(target.fallbackParagraphId)
    }

    func testTargetFallsBackToProgressionWhenPositionsMissing() {
        let paragraph = paragraph(id: 7, resourceHref: "Text/ch1.xhtml", wordIds: Array(100...109))
        let target = EPUBAutoAdvanceDecider.target(
            for: paragraph,
            wordIndex: 104,
            positionsByResourceHref: [:],
            wordRangesByResourceHref: ["Text/ch1.xhtml": EPUBResourceWordRange(firstWordId: 100, lastWordId: 109)]
        )

        XCTAssertNil(target.position)
        XCTAssertEqual(target.progression ?? -1, 4.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(target.fallbackParagraphId)
    }

    func testTargetDoesNotSynthesizePositionWhenReadiumPositionIsMissing() {
        let paragraph = paragraph(id: 7, resourceHref: "Text/ch1.xhtml", wordIds: Array(100...109))
        let target = EPUBAutoAdvanceDecider.target(
            for: paragraph,
            wordIndex: 104,
            positionsByResourceHref: ["Text/ch1.xhtml": [nil, nil, nil]],
            wordRangesByResourceHref: ["Text/ch1.xhtml": EPUBResourceWordRange(firstWordId: 100, lastWordId: 109)]
        )

        XCTAssertNil(target.position)
        XCTAssertEqual(target.progression ?? -1, 4.0 / 9.0, accuracy: 0.0001)
    }

    func testTargetFallsBackToParagraphWhenNoRangeIsAvailable() {
        let paragraph = paragraph(id: 7, resourceHref: "Text/ch1.xhtml", wordIds: Array(100...109))
        let target = EPUBAutoAdvanceDecider.target(
            for: paragraph,
            wordIndex: 104,
            positionsByResourceHref: [:],
            wordRangesByResourceHref: [:]
        )

        XCTAssertEqual(target, autoAdvanceTarget(position: nil, progression: nil, fallbackParagraphId: 7))
    }

    private func autoAdvanceTarget(
        resourceHref: String = "Text/ch1.xhtml",
        position: Int?,
        progression: Double? = nil,
        fallbackParagraphId: Int? = nil
    ) -> EPUBAutoAdvanceTarget {
        EPUBAutoAdvanceTarget(
            resourceHref: resourceHref,
            position: position,
            progression: progression,
            fallbackParagraphId: fallbackParagraphId
        )
    }

    private func visibleTarget(
        resourceHrefs: [String],
        positions: ClosedRange<Int>? = nil,
        progressions: [String: ClosedRange<Double>] = [:]
    ) -> EPUBVisibleAutoAdvanceTarget {
        EPUBVisibleAutoAdvanceTarget(
            resourceHrefs: resourceHrefs,
            positionRange: positions,
            progressionsByResourceHref: progressions
        )
    }

    private func paragraph(id: Int, resourceHref: String, wordIds: [Int]) -> BookParagraph {
        let words = wordIds.map { BookWord(id: $0, text: "w\($0)", paragraphId: id) }
        return BookParagraph(
            id: id,
            text: words.map(\.text).joined(separator: " "),
            words: words,
            chapterIndex: 0,
            isHeading: false,
            resourceHref: resourceHref
        )
    }
}
