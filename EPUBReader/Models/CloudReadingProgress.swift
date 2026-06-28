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

    /// Derives a short iCloud key from book name and format so imports with different UUIDs can match.
    static func storageKey(for book: BookMetadata) -> String {
        "rp.v1.\(digest(for: bookKey(for: book)))"
    }

    static func bookKey(for book: BookMetadata) -> String {
        let title = normalized(book.title.isEmpty ? BookMetadata.fallbackTitle(forFileName: book.fileName) : book.title)
        return "\(book.format.rawValue):\(title)"
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
}
