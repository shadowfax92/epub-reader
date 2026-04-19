import Foundation

struct PlaybackHighlightTiming: Equatable {
    let globalWordIndex: Int
    let startTime: Double
    let endTime: Double
}

enum PlaybackHighlightHelper {
    static func timingIndex(
        for currentTime: Double,
        timings: [PlaybackHighlightTiming],
        previousIndex: Int
    ) -> Int? {
        guard !timings.isEmpty else { return nil }

        var index = min(max(previousIndex, 0), timings.count - 1)

        if currentTime < timings[index].startTime {
            while index > 0 && currentTime < timings[index].startTime {
                index -= 1
            }
        }

        while index + 1 < timings.count && timings[index + 1].startTime <= currentTime {
            index += 1
        }

        return index
    }

    static func shouldPublishHighlight(
        resolvedWordIndex: Int,
        displayedWordIndex: Int,
        currentTime: Double,
        lastPublishedTime: Double,
        minimumInterval: Double,
        isLastWord: Bool
    ) -> Bool {
        guard resolvedWordIndex != displayedWordIndex else { return false }
        if isLastWord { return true }
        return currentTime - lastPublishedTime >= minimumInterval
    }
}
