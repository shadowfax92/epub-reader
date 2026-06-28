import CryptoKit
import Foundation

struct CloudReadingProgress: Codable, Equatable {
    let bookKey: String
    let bookTitle: String
    let format: BookFormat
    let pageIndex: Int?
    let displayPage: Int?
    let locatorJSONString: String?
    let readingPosition: ReadingPosition?
    let updatedAt: Date

    /// Builds the synced reading-progress payload shared across local restore and iCloud.
    init(
        book: BookMetadata,
        pageIndex: Int? = nil,
        displayPage: Int? = nil,
        locatorJSONString: String? = nil,
        readingPosition: ReadingPosition? = nil,
        updatedAt: Date = Date()
    ) {
        self.bookKey = Self.bookKey(for: book)
        self.bookTitle = book.title
        self.format = book.format
        self.pageIndex = pageIndex
        self.displayPage = displayPage ?? pageIndex.map { $0 + 1 }
        self.locatorJSONString = locatorJSONString
        self.readingPosition = readingPosition
        self.updatedAt = updatedAt
    }

    var pageLabel: String {
        if let displayPage {
            return "Page \(displayPage)"
        }
        return "Latest Page"
    }

    func isNewer(than other: CloudReadingProgress?) -> Bool {
        guard let other else { return true }
        return updatedAt > other.updatedAt
    }

    func withUpdatedAt(_ updatedAt: Date) -> CloudReadingProgress {
        CloudReadingProgress(
            bookKey: bookKey,
            bookTitle: bookTitle,
            format: format,
            pageIndex: pageIndex,
            displayPage: displayPage,
            locatorJSONString: locatorJSONString,
            readingPosition: readingPosition,
            updatedAt: updatedAt
        )
    }

    /// Derives a short iCloud key from stable book metadata so imports with different UUIDs can match.
    static func storageKey(for book: BookMetadata) -> String {
        "rp.v2.\(digest(for: bookKey(for: book)))"
    }

    static func bookKey(for book: BookMetadata) -> String {
        if let contentFingerprint = normalizedFingerprint(book.contentFingerprint) {
            return "\(book.format.rawValue):fingerprint:\(contentFingerprint)"
        }

        let title = normalized(book.title.isEmpty ? BookMetadata.fallbackTitle(forFileName: book.fileName) : book.title)
        let author = normalized(book.author)
        let disambiguator = author.isEmpty || author == normalized("Unknown Author")
            ? "file:\(normalized(BookMetadata.fallbackTitle(forFileName: book.fileName)))"
            : "author:\(author)"
        return "\(book.format.rawValue):title:\(title):\(disambiguator)"
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func digest(for value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedFingerprint(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }

    private init(
        bookKey: String,
        bookTitle: String,
        format: BookFormat,
        pageIndex: Int?,
        displayPage: Int?,
        locatorJSONString: String?,
        readingPosition: ReadingPosition?,
        updatedAt: Date
    ) {
        self.bookKey = bookKey
        self.bookTitle = bookTitle
        self.format = format
        self.pageIndex = pageIndex
        self.displayPage = displayPage
        self.locatorJSONString = locatorJSONString
        self.readingPosition = readingPosition
        self.updatedAt = updatedAt
    }
}
