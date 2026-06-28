import Foundation

struct EPUBResourceWordRange {
    let firstWordId: Int
    let lastWordId: Int

    var wordCount: Int { lastWordId - firstWordId + 1 }
}

struct EPUBAutoAdvanceTarget: Equatable {
    let resourceHref: String
    let position: Int?
    let progression: Double?
    let fallbackParagraphId: Int?
}

struct EPUBVisibleAutoAdvanceTarget: Equatable {
    let resourceHrefs: [String]
    let positionRange: ClosedRange<Int>?
    let progressionsByResourceHref: [String: ClosedRange<Double>]
}

struct EPUBAutoAdvanceDecision: Equatable {
    let shouldAdvance: Bool
    let nextLastTarget: EPUBAutoAdvanceTarget?
}

enum EPUBAutoAdvanceDecider {
    /// Maps the spoken EPUB word to the Readium position used for page-following.
    static func target(
        for paragraph: BookParagraph,
        wordIndex: Int,
        positionsByResourceHref: [String: [Int?]],
        wordRangesByResourceHref: [String: EPUBResourceWordRange]
    ) -> EPUBAutoAdvanceTarget {
        let progression = estimatedProgression(
            resourceHref: paragraph.resourceHref,
            wordIndex: wordIndex,
            wordRangesByResourceHref: wordRangesByResourceHref
        )
        let position = estimatedReadiumPosition(
            resourceHref: paragraph.resourceHref,
            progression: progression,
            positionsByResourceHref: positionsByResourceHref,
            wordRangesByResourceHref: wordRangesByResourceHref
        )
        return EPUBAutoAdvanceTarget(
            resourceHref: paragraph.resourceHref,
            position: position,
            progression: progression,
            fallbackParagraphId: position == nil && progression == nil ? paragraph.id : nil
        )
    }

    /// Decides whether speech should move the page and which target should be remembered.
    static func decide(
        target: EPUBAutoAdvanceTarget,
        visibleTarget: EPUBVisibleAutoAdvanceTarget?,
        lastTarget: EPUBAutoAdvanceTarget?,
        isEnabled: Bool,
        isPlaying: Bool
    ) -> EPUBAutoAdvanceDecision {
        guard isEnabled, isPlaying else {
            return EPUBAutoAdvanceDecision(shouldAdvance: false, nextLastTarget: nil)
        }

        if isVisible(target, visibleTarget: visibleTarget) {
            return EPUBAutoAdvanceDecision(shouldAdvance: false, nextLastTarget: target)
        }
        guard target != lastTarget else {
            return EPUBAutoAdvanceDecision(shouldAdvance: false, nextLastTarget: lastTarget)
        }
        return EPUBAutoAdvanceDecision(shouldAdvance: true, nextLastTarget: target)
    }

    /// Builds per-resource word ranges so speech progress can be mapped into page positions.
    static func wordRangesByResourceHref(from parsedBook: ParsedBook) -> [String: EPUBResourceWordRange] {
        var result: [String: EPUBResourceWordRange] = [:]
        for paragraph in parsedBook.flatParagraphs {
            guard let firstWordId = paragraph.words.first?.id,
                  let lastWordId = paragraph.words.last?.id else { continue }

            if let existing = result[paragraph.resourceHref] {
                let first = min(existing.firstWordId, firstWordId)
                let last = max(existing.lastWordId, lastWordId)
                result[paragraph.resourceHref] = EPUBResourceWordRange(firstWordId: first, lastWordId: last)
            } else {
                result[paragraph.resourceHref] = EPUBResourceWordRange(firstWordId: firstWordId, lastWordId: lastWordId)
            }
        }
        return result
    }

    /// Estimates the nearest Readium position for a spoken word in a resource.
    static func estimatedReadiumPosition(
        resourceHref: String,
        progression: Double?,
        positionsByResourceHref: [String: [Int?]],
        wordRangesByResourceHref: [String: EPUBResourceWordRange]
    ) -> Int? {
        guard let positions = positionsByResourceHref[resourceHref],
              !positions.isEmpty,
              wordRangesByResourceHref[resourceHref] != nil,
              let progression else { return nil }

        let positionIndex = min(positions.count - 1, Int(floor(progression * Double(positions.count))))
        return positions[positionIndex]
    }

    private static func estimatedProgression(
        resourceHref: String,
        wordIndex: Int,
        wordRangesByResourceHref: [String: EPUBResourceWordRange]
    ) -> Double? {
        guard let range = wordRangesByResourceHref[resourceHref],
              range.wordCount > 0 else { return nil }

        let relativeWordIndex = min(max(0, wordIndex - range.firstWordId), range.wordCount - 1)
        return Double(relativeWordIndex) / Double(max(1, range.wordCount - 1))
    }

    private static func isVisible(_ target: EPUBAutoAdvanceTarget, visibleTarget: EPUBVisibleAutoAdvanceTarget?) -> Bool {
        guard let visibleTarget,
              visibleTarget.resourceHrefs.contains(where: { TTSHighlightHelper.hrefsMatch(target.resourceHref, $0) }) else { return false }
        if let progression = target.progression,
           let visibleProgression = visibleTarget.progressionRange(for: target.resourceHref) {
            return visibleProgression.contains(progression)
        }
        if let position = target.position, let positionRange = visibleTarget.positionRange {
            return positionRange.contains(position)
        }
        return target.position == nil
            && target.progression == nil
            && target.fallbackParagraphId != nil
    }
}

extension EPUBVisibleAutoAdvanceTarget {
    func progressionRange(for resourceHref: String) -> ClosedRange<Double>? {
        for (href, progression) in progressionsByResourceHref where TTSHighlightHelper.hrefsMatch(resourceHref, href) {
            return progression
        }
        return nil
    }
}

/// Serializes speech-driven EPUB page turns: only one turn is in flight at a time, and
/// no further turn is issued until Readium's viewport confirms the new page is on screen.
///
/// Readium drops a `.jump` issued while another is still `.jumping`, and its visible range
/// only refreshes (via `viewportDidChange`) after a jump settles to `.idle`. The previous
/// cancel-and-reissue-every-word approach therefore raced that settle window and pages
/// intermittently failed to follow narration. This gate closes the window.
struct SpeechPageFollowCoordinator {
    private(set) var isAwaitingViewport = false

    /// Arms the gate and reports whether a page turn should be issued now. Returns `true`
    /// only for an advance verdict when no prior turn is still awaiting confirmation.
    mutating func shouldIssueTurn(wantsAdvance: Bool) -> Bool {
        guard wantsAdvance, !isAwaitingViewport else { return false }
        isAwaitingViewport = true
        return true
    }

    /// The navigator reported a viewport change — the new page is on screen, so the next
    /// turn may be considered.
    mutating func viewportDidSettle() { isAwaitingViewport = false }

    /// The jump was rejected or a no-op (`go` returned `false`), so no viewport change is
    /// coming; release the gate immediately.
    mutating func turnDidNotMove() { isAwaitingViewport = false }

    /// Playback started or stopped — no follow should straddle the transition.
    mutating func reset() { isAwaitingViewport = false }
}
