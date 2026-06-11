import Foundation

/// O(1) lookups for the per-word highlight path, exploiting two parser
/// invariants (EPUBParserService): a paragraph's id is its index in
/// flatParagraphs, and global word ids are contiguous within a paragraph.
/// Every lookup verifies the invariant and falls back to a scan on any miss
/// (absent id or broken invariant — exhaustion alone can't tell them apart),
/// so they're fast when well-formed and never wrong.
extension ParsedBook {
    func paragraph(withId id: Int) -> BookParagraph? {
        if let candidate = flatParagraphs[safe: id], candidate.id == id {
            return candidate
        }
        return flatParagraphs.first { $0.id == id }
    }
}

extension BookParagraph {
    func position(ofGlobalWordId id: Int) -> Int? {
        guard let firstId = words.first?.id else { return nil }
        if let candidate = words[safe: id - firstId], candidate.id == id {
            return id - firstId
        }
        return words.firstIndex { $0.id == id }
    }
}

extension Array where Element == BookParagraph {
    /// Binary search over the ordered global word-id ranges of the paragraphs.
    func indexOfParagraph(containingWordId id: Int) -> Int? {
        var lo = 0
        var hi = count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            guard let first = self[mid].words.first?.id,
                  let last = self[mid].words.last?.id else { break }
            if id < first {
                hi = mid - 1
            } else if id > last {
                lo = mid + 1
            } else {
                return mid
            }
        }
        return firstIndex { paragraph in paragraph.words.contains { $0.id == id } }
    }
}
