import Foundation

enum TTSHighlightHelper {
    /// Checks if two EPUB resource hrefs refer to the same resource,
    /// accounting for fragment identifiers and absolute/relative URL differences.
    static func hrefsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let cleanA = a.components(separatedBy: "#").first ?? a
        let cleanB = b.components(separatedBy: "#").first ?? b
        if cleanA == cleanB { return true }
        return cleanA.hasSuffix("/" + cleanB) || cleanB.hasSuffix("/" + cleanA)
    }

    /// Builds context text for the word at `wordPosition` in the given word array.
    /// Uses ALL words in the paragraph as context for reliable TextQuoteAnchor matching.
    static func buildTextContext(
        words: [BookWord],
        wordPosition: Int
    ) -> (before: String?, highlight: String, after: String?) {
        guard wordPosition >= 0, wordPosition < words.count else {
            return (nil, "", nil)
        }

        let highlight = words[wordPosition].text
        let beforeText = words.prefix(wordPosition).map(\.text).joined(separator: " ")
        let afterText = words.dropFirst(wordPosition + 1).map(\.text).joined(separator: " ")

        return (
            before: beforeText.isEmpty ? nil : beforeText,
            highlight: highlight,
            after: afterText.isEmpty ? nil : afterText
        )
    }

    /// Finds the paragraph and word indices matching a selected text within parsed paragraphs.
    static func findStartPosition(
        selectedText: String,
        hrefString: String,
        paragraphs: [BookParagraph]
    ) -> (paragraphIndex: Int, wordIndex: Int)? {
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let selectedWords = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard let firstSelectedWord = selectedWords.first else { return nil }

        // First pass: match paragraph text + first word
        for (index, paragraph) in paragraphs.enumerated() {
            guard hrefsMatch(paragraph.resourceHref, hrefString) else { continue }
            if paragraph.text.contains(trimmed),
               let matchingWord = paragraph.words.first(where: { $0.text == firstSelectedWord }) {
                return (paragraphIndex: index, wordIndex: matchingWord.id)
            }
        }

        // Second pass: match first selected word, but only if the selection is a single word
        // (multi-word selections that didn't match a paragraph in pass 1 are too ambiguous)
        if selectedWords.count == 1 {
            for (index, paragraph) in paragraphs.enumerated() {
                guard hrefsMatch(paragraph.resourceHref, hrefString) else { continue }
                if let matchingWord = paragraph.words.first(where: { $0.text == firstSelectedWord }) {
                    return (paragraphIndex: index, wordIndex: matchingWord.id)
                }
            }
        }

        return nil
    }
}
