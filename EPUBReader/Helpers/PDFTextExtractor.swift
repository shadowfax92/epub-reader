import Foundation

/// Tokenizes a PDF page's extracted text into TTS paragraph blocks, recording each
/// word's UTF-16 range in the page string so it can be mapped back to on-page
/// geometry via `PDFPage.selection(for:)`.
enum PDFTextExtractor {

    struct Token: Equatable {
        /// Spoken text — de-hyphenated when the word was split across a line break.
        let text: String
        /// Range in the source page string (NSString semantics), spanning all fragments.
        let range: NSRange
    }

    struct ParagraphBlock: Equatable {
        let tokens: [Token]
    }

    // PDFs often have no blank lines, so a page would become one giant TTS request;
    // caps keep audio chunks sized like EPUB paragraphs.
    static let softWordCap = 100
    static let hardWordCap = 150

    static func paragraphs(from pageString: String) -> [ParagraphBlock] {
        let tokens = mergeHyphenatedLineBreaks(tokenize(pageString))

        var blocks: [ParagraphBlock] = []
        var current: [Token] = []

        func flush() {
            if !current.isEmpty {
                blocks.append(ParagraphBlock(tokens: current))
                current = []
            }
        }

        for entry in tokens {
            if entry.lineBreaksBefore >= 2 { flush() }
            current.append(entry.token)
            if current.count >= hardWordCap {
                flush()
            } else if current.count >= softWordCap, endsSentence(entry.token.text) {
                flush()
            }
        }
        flush()
        return blocks
    }

    // MARK: - Tokenization

    private struct RawToken {
        var token: Token
        /// Number of line breaks (\n, \r, \r\n, U+2028/2029 — CRLF counts once) in the gap before this token.
        var lineBreaksBefore: Int
    }

    private static func tokenize(_ pageString: String) -> [RawToken] {
        let ns = pageString as NSString
        let length = ns.length
        var result: [RawToken] = []
        var pendingBreaks = 0
        var i = 0

        while i < length {
            let c = ns.character(at: i)
            if isWhitespace(c) {
                if c == 0x0D {
                    pendingBreaks += 1
                    if i + 1 < length, ns.character(at: i + 1) == 0x0A { i += 1 }
                } else if isLineBreak(c) {
                    pendingBreaks += 1
                }
                i += 1
                continue
            }

            let start = i
            while i < length, !isWhitespace(ns.character(at: i)) { i += 1 }
            let range = NSRange(location: start, length: i - start)
            result.append(RawToken(
                token: Token(text: ns.substring(with: range), range: range),
                lineBreaksBefore: pendingBreaks
            ))
            pendingBreaks = 0
        }
        return result
    }

    /// Joins `exam-\nple` into one token `example` whose range spans both fragments.
    /// Always drops the hyphen: soft end-of-line hyphenation vastly outnumbers split
    /// compounds, and the spoken difference is negligible.
    private static func mergeHyphenatedLineBreaks(_ tokens: [RawToken]) -> [RawToken] {
        var merged: [RawToken] = []
        for entry in tokens {
            if let last = merged.last,
               entry.lineBreaksBefore == 1,
               last.token.text.hasSuffix("-"),
               last.token.text.count > 1 {
                let text = String(last.token.text.dropLast()) + entry.token.text
                let range = NSUnionRange(last.token.range, entry.token.range)
                merged[merged.count - 1] = RawToken(
                    token: Token(text: text, range: range),
                    lineBreaksBefore: last.lineBreaksBefore
                )
            } else {
                merged.append(entry)
            }
        }
        return merged
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false } // surrogate halves are token content
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Matches CharacterSet.newlines minus \r (handled by the CRLF pairing branch).
    private static func isLineBreak(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0B || c == 0x0C || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    private static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}", "»"]
        var trimmed = Substring(text)
        while let last = trimmed.last, closers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "…"
    }
}
