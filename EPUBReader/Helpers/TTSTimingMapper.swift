import Foundation

struct WordTiming {
    let globalWordIndex: Int
    let startTime: Double
    let endTime: Double
}

/// Maps TTS character-level alignment to per-word timings and answers "which
/// word is speaking at time t". Pure functions, kept out of AudioPlaybackManager
/// so they're testable without AVFoundation.
enum TTSTimingMapper {
    /// Pairs whitespace-delimited character runs with book words 1:1.
    /// Walking runs (not input word lengths) stays accurate when TTS
    /// normalization changes character counts ("2022" → "twenty twenty-two");
    /// if run and word counts still disagree, falls back to proportional
    /// distribution over the alignment's time span instead of drifting.
    static func mapAlignment(characters: [String], startTimes: [Double], endTimes: [Double], words: [BookWord]) -> [WordTiming] {
        let count = min(characters.count, startTimes.count, endTimes.count)
        guard count > 0, !words.isEmpty else { return [] }

        var runs: [(start: Int, end: Int)] = []
        var runStart: Int?
        for i in 0..<count {
            let isSeparator = characters[i].allSatisfy(\.isWhitespace)
            if isSeparator {
                if let start = runStart {
                    runs.append((start, i - 1))
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = i
            }
        }
        if let start = runStart {
            runs.append((start, count - 1))
        }

        guard runs.count == words.count else {
            let span = endTimes[count - 1] - startTimes[0]
            return proportionalTimings(words: words, duration: span, offset: startTimes[0])
        }

        return zip(words, runs).map { word, run in
            WordTiming(globalWordIndex: word.id, startTime: startTimes[run.start], endTime: endTimes[run.end])
        }
    }

    /// Distributes a known audio duration across words by character count
    /// (one extra unit per inter-word gap). Used for providers without
    /// timestamps and as the alignment-mismatch fallback.
    static func proportionalTimings(words: [BookWord], duration: Double, offset: Double = 0) -> [WordTiming] {
        guard !words.isEmpty, duration > 0 else { return [] }
        let totalUnits = words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1)
        guard totalUnits > 0 else { return [] }

        let timePerUnit = duration / Double(totalUnits)
        var timings: [WordTiming] = []
        var current = offset
        for (i, word) in words.enumerated() {
            let span = Double(word.text.count) * timePerUnit
            timings.append(WordTiming(globalWordIndex: word.id, startTime: current, endTime: current + span))
            current += span
            if i < words.count - 1 {
                current += timePerUnit
            }
        }
        return timings
    }

    /// Last word whose startTime <= time, via binary search over timings
    /// sorted by startTime. Nil when time precedes the first word.
    static func currentWordIndex(timings: [WordTiming], at time: Double) -> Int? {
        var lo = 0
        var hi = timings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if timings[mid].startTime <= time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo > 0 ? timings[lo - 1].globalWordIndex : nil
    }
}
