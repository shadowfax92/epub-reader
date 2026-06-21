import Foundation

enum TTSHighlightHelper {
    /// Checks whether two EPUB hrefs point at the same resource.
    static func hrefsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let cleanA = a.components(separatedBy: "#").first ?? a
        let cleanB = b.components(separatedBy: "#").first ?? b
        if cleanA == cleanB { return true }
        return cleanA.hasSuffix("/" + cleanB) || cleanB.hasSuffix("/" + cleanA)
    }

    /// Builds the capped TextQuoteAnchor context for a spoken word.
    static func buildTextContext(
        words: [BookWord],
        wordPosition: Int,
        maxContextChars: Int = 64
    ) -> (before: String?, highlight: String, after: String?) {
        guard wordPosition >= 0, wordPosition < words.count else {
            return (nil, "", nil)
        }

        let highlight = words[wordPosition].text

        var beforeParts: [String] = []
        var beforeLength = 0
        var index = wordPosition - 1
        while index >= 0 && beforeLength <= maxContextChars {
            let text = words[index].text
            beforeParts.append(text)
            beforeLength += text.count + 1
            index -= 1
        }
        let beforeText = String(beforeParts.reversed().joined(separator: " ").suffix(maxContextChars))

        var afterParts: [String] = []
        var afterLength = 0
        index = wordPosition + 1
        while index < words.count && afterLength <= maxContextChars {
            let text = words[index].text
            afterParts.append(text)
            afterLength += text.count + 1
            index += 1
        }
        let afterText = String(afterParts.joined(separator: " ").prefix(maxContextChars))

        return (
            before: beforeText.isEmpty ? nil : beforeText,
            highlight: highlight,
            after: afterText.isEmpty ? nil : afterText
        )
    }

    /// Finds the playback start position for selected text in a parsed EPUB resource.
    static func findStartPosition(
        selectedText: String,
        hrefString: String,
        paragraphs: [BookParagraph]
    ) -> (paragraphIndex: Int, wordIndex: Int)? {
        let selectedWords = normalizedWords(in: selectedText)
        guard let firstSelectedWord = selectedWords.first else { return nil }

        for (index, paragraph) in paragraphs.enumerated() {
            guard hrefsMatch(paragraph.resourceHref, hrefString) else { continue }
            let paragraphWords = paragraph.words.map { normalizedForSelectionMatching($0.text) }
            if let start = phraseStart(selectedWords, in: paragraphWords) {
                return (paragraphIndex: index, wordIndex: paragraph.words[start].id)
            }
        }

        if selectedWords.count == 1 {
            for (index, paragraph) in paragraphs.enumerated() {
                guard hrefsMatch(paragraph.resourceHref, hrefString) else { continue }
                if let matchingWord = paragraph.words.first(where: { normalizedForSelectionMatching($0.text) == firstSelectedWord }) {
                    return (paragraphIndex: index, wordIndex: matchingWord.id)
                }
            }
        }

        return nil
    }

    /// Normalizes parser and Readium selection text into the same comparison form.
    private static func normalizedForSelectionMatching(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedWords(in text: String) -> [String] {
        normalizedForSelectionMatching(text)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
    }

    private static func phraseStart(_ phrase: [String], in words: [String]) -> Int? {
        guard !phrase.isEmpty, phrase.count <= words.count else { return nil }

        for start in 0...(words.count - phrase.count) {
            let end = start + phrase.count
            if zip(words[start..<end], phrase).allSatisfy({ pair in pair.0 == pair.1 }) {
                return start
            }
        }
        return nil
    }
}
