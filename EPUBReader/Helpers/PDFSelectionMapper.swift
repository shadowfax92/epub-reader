import Foundation

/// Maps a PDF text selection back to a playback start position, mirroring what
/// TTSHighlightHelper.findStartPosition does for EPUB selections.
enum PDFSelectionMapper {

    /// Resolution order: geometric offset probe (validated against the selection text —
    /// `characterIndex(at:)` can misfire), exact text search, then first-word match on the
    /// page. `selectionStartOffset` is the selection's UTF-16 offset in the page string.
    static func findStartPosition(
        selectionText: String,
        selectionStartOffset: Int?,
        pageIndex: Int,
        pageString: String,
        paragraphs: [BookParagraph],
        wordLocations: [PDFWordLocation]
    ) -> (paragraphIndex: Int, wordIndex: Int)? {
        let trimmed = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .first(where: { !$0.isEmpty }) else { return nil }

        let ns = pageString as NSString

        if let offset = selectionStartOffset, offset >= 0, offset < ns.length,
           let match = wordMatch(at: offset, pageIndex: pageIndex,
                                 paragraphs: paragraphs, wordLocations: wordLocations),
           match.word.text == firstWord || match.word.text.contains(firstWord) {
            return (match.paragraphIndex, match.word.id)
        }

        let searchRange = ns.range(of: trimmed)
        if searchRange.location != NSNotFound,
           let match = wordMatch(at: searchRange.location, pageIndex: pageIndex,
                                 paragraphs: paragraphs, wordLocations: wordLocations) {
            return (match.paragraphIndex, match.word.id)
        }

        for (index, paragraph) in paragraphs.enumerated() {
            for word in paragraph.words {
                guard wordLocations[safe: word.id]?.pageIndex == pageIndex else { continue }
                if word.text == firstWord {
                    return (paragraphIndex: index, wordIndex: word.id)
                }
            }
        }
        return nil
    }

    /// First word on the page whose range ends after `location` — i.e. the word containing
    /// the location, or the next one when the location falls in inter-word whitespace.
    private static func wordMatch(
        at location: Int,
        pageIndex: Int,
        paragraphs: [BookParagraph],
        wordLocations: [PDFWordLocation]
    ) -> (paragraphIndex: Int, word: BookWord)? {
        for (index, paragraph) in paragraphs.enumerated() {
            for word in paragraph.words {
                guard let loc = wordLocations[safe: word.id], loc.pageIndex == pageIndex else { continue }
                if loc.range.location + loc.range.length > location {
                    return (paragraphIndex: index, word: word)
                }
            }
        }
        return nil
    }
}
