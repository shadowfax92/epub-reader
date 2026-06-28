import CryptoKit
import Foundation

struct CloudReadingProgress: Codable, Equatable, Sendable {
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

    func withReadingPosition(_ readingPosition: ReadingPosition?) -> CloudReadingProgress {
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

    func migrated(to book: BookMetadata) -> CloudReadingProgress {
        CloudReadingProgress(
            bookKey: Self.bookKey(for: book),
            bookTitle: book.title,
            format: book.format,
            pageIndex: pageIndex,
            displayPage: displayPage,
            locatorJSONString: locatorJSONString,
            readingPosition: readingPosition,
            updatedAt: updatedAt
        )
    }

    /// Derives a short iCloud key from stable book metadata so imports with different UUIDs can match.
    static func storageKey(for book: BookMetadata) -> String {
        storageKey(forBookKey: bookKey(for: book))
    }

    static func storageKeys(for book: BookMetadata) -> [String] {
        uniqueBookKeys(for: book).map(storageKey(forBookKey:))
    }

    static func storageKey(forBookKey bookKey: String) -> String {
        "rp.v2.\(digest(for: bookKey))"
    }

    static func bookKey(for book: BookMetadata) -> String {
        if let fingerprint = normalizedFingerprint(book.contentFingerprint) {
            return "\(book.format.rawValue):content:\(fingerprint)"
        }
        return metadataBookKey(for: book)
    }

    static func matches(_ progress: CloudReadingProgress, book: BookMetadata) -> Bool {
        uniqueBookKeys(for: book).contains(progress.bookKey)
    }

    private static func uniqueBookKeys(for book: BookMetadata) -> [String] {
        var result: [String] = []
        for key in [bookKey(for: book), metadataBookKey(for: book)] where !result.contains(key) {
            result.append(key)
        }
        return result
    }

    private static func metadataBookKey(for book: BookMetadata) -> String {
        let title = normalized(book.title.isEmpty ? BookMetadata.fallbackTitle(forFileName: book.fileName) : book.title)
        let author = normalized(book.author)
        let fileName = normalized(BookMetadata.fallbackTitle(forFileName: book.fileName))
        guard !author.isEmpty, author != normalized("Unknown Author") else {
            return "\(book.format.rawValue):title:\(title):file:\(fileName)"
        }
        return "\(book.format.rawValue):title:\(title):author:\(author):file:\(fileName)"
    }

    private static func normalizedFingerprint(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
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
