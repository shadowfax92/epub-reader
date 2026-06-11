import Foundation

/// Maps a PDF text selection back to a playback start position, mirroring what
/// TTSHighlightHelper.findStartPosition does for EPUB selections.
enum PDFSelectionMapper {

    /// `selectionStartOffset` is the selection's UTF-16 offset in the page string when the
    /// caller can compute it (disambiguates repeated phrases); otherwise the first occurrence
    /// of the selection text wins, falling back to a first-word text match on the page.
    static func findStartPosition(
        selectionText: String,
        selectionStartOffset: Int?,
        pageIndex: Int,
        pageString: String,
        paragraphs: [BookParagraph],
        wordLocations: [PDFWordLocation]
    ) -> (paragraphIndex: Int, wordIndex: Int)? {
        let trimmed = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let location = resolveLocation(of: trimmed, offset: selectionStartOffset, in: pageString),
           let position = wordPosition(at: location, pageIndex: pageIndex,
                                       paragraphs: paragraphs, wordLocations: wordLocations) {
            return position
        }

        guard let firstWord = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .first(where: { !$0.isEmpty }) else { return nil }

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

    private static func resolveLocation(of trimmed: String, offset: Int?, in pageString: String) -> Int? {
        let ns = pageString as NSString
        if let offset, offset >= 0, offset < ns.length {
            return offset
        }
        let range = ns.range(of: trimmed)
        return range.location == NSNotFound ? nil : range.location
    }

    /// First word on the page whose range ends after `location` — i.e. the word containing
    /// the location, or the next one when the location falls in inter-word whitespace.
    private static func wordPosition(
        at location: Int,
        pageIndex: Int,
        paragraphs: [BookParagraph],
        wordLocations: [PDFWordLocation]
    ) -> (paragraphIndex: Int, wordIndex: Int)? {
        for (index, paragraph) in paragraphs.enumerated() {
            for word in paragraph.words {
                guard let loc = wordLocations[safe: word.id], loc.pageIndex == pageIndex else { continue }
                if loc.range.location + loc.range.length > location {
                    return (paragraphIndex: index, wordIndex: word.id)
                }
            }
        }
        return nil
    }
}
