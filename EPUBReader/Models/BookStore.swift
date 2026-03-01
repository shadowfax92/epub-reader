import SwiftUI

@MainActor
class BookStore: ObservableObject {
    @Published var books: [BookMetadata] = []

    private let defaults = UserDefaults.standard

    var apiKey: String {
        get { defaults.string(forKey: "elevenLabsApiKey") ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "elevenLabsApiKey") }
    }

    var selectedVoiceId: String {
        get { defaults.string(forKey: "selectedVoiceId") ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "selectedVoiceId") }
    }

    var selectedVoiceName: String {
        get { defaults.string(forKey: "selectedVoiceName") ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "selectedVoiceName") }
    }

    var playbackSpeed: Double {
        get {
            let v = defaults.double(forKey: "playbackSpeed")
            return v > 0 ? v : 1.0
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "playbackSpeed") }
    }

    var fontSize: Double {
        get {
            let v = defaults.double(forKey: "readerFontSize")
            return v > 0 ? v : 17.0
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "readerFontSize") }
    }

    var isPagedMode: Bool {
        get { defaults.bool(forKey: "isPagedMode") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "isPagedMode") }
    }

    private let booksDirectoryURL: URL
    private let metadataFileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectoryURL = docs.appendingPathComponent("Books")
        metadataFileURL = docs.appendingPathComponent("books_metadata.json")

        try? FileManager.default.createDirectory(at: booksDirectoryURL, withIntermediateDirectories: true)
        loadBooks()
    }

    func importBook(from sourceURL: URL) throws -> BookMetadata {
        let fileName = sourceURL.lastPathComponent
        let destURL = booksDirectoryURL.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let parsed = try EPUBParserService.shared.parseMetadata(from: destURL)

        let book = BookMetadata(
            id: UUID(),
            title: parsed.title ?? fileName.replacingOccurrences(of: ".epub", with: ""),
            author: parsed.author ?? "Unknown Author",
            fileName: fileName,
            dateAdded: Date()
        )

        books.insert(book, at: 0)
        saveBooks()
        return book
    }

    func removeBook(_ book: BookMetadata) {
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: book.fileURL)
        defaults.removeObject(forKey: "position_\(book.id.uuidString)")
        saveBooks()
    }

    func saveReadingPosition(bookId: UUID, position: ReadingPosition) {
        if let data = try? JSONEncoder().encode(position) {
            defaults.set(data, forKey: "position_\(bookId.uuidString)")
        }
    }

    func getReadingPosition(bookId: UUID) -> ReadingPosition? {
        guard let data = defaults.data(forKey: "position_\(bookId.uuidString)") else { return nil }
        return try? JSONDecoder().decode(ReadingPosition.self, from: data)
    }

    private func loadBooks() {
        guard let data = try? Data(contentsOf: metadataFileURL),
              let decoded = try? JSONDecoder().decode([BookMetadata].self, from: data) else { return }
        books = decoded
    }

    private func saveBooks() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: metadataFileURL, options: .atomic)
    }
}
