import SwiftUI
import ReadiumShared

@MainActor
class BookStore: ObservableObject {
    @Published var books: [BookMetadata] = []

    private let defaults = UserDefaults.standard

    var ttsProvider: TTSProviderType {
        get { TTSProviderType(rawValue: defaults.string(forKey: "ttsProvider") ?? "") ?? .elevenLabs }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: "ttsProvider") }
    }

    // MARK: - ElevenLabs Settings

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

    // MARK: - OpenAI Settings

    var openAIApiKey: String {
        get { defaults.string(forKey: "openAIApiKey") ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "openAIApiKey") }
    }

    var openAIVoiceId: String {
        get { defaults.string(forKey: "openAIVoiceId") ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "openAIVoiceId") }
    }

    var openAIVoiceName: String {
        get { defaults.string(forKey: "openAIVoiceName") ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "openAIVoiceName") }
    }

    // MARK: - Active Provider Helpers

    var activeApiKey: String {
        switch ttsProvider {
        case .elevenLabs: return apiKey
        case .openAI: return openAIApiKey
        }
    }

    var activeVoiceId: String {
        switch ttsProvider {
        case .elevenLabs: return selectedVoiceId
        case .openAI: return openAIVoiceId
        }
    }

    var activeVoiceName: String {
        switch ttsProvider {
        case .elevenLabs: return selectedVoiceName
        case .openAI: return openAIVoiceName
        }
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

    var readerTheme: ReaderTheme {
        get { ReaderTheme(rawValue: defaults.string(forKey: "readerTheme") ?? "system") ?? .system }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: "readerTheme") }
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

    func importBook(from sourceURL: URL) async throws -> BookMetadata {
        let fileName = sourceURL.lastPathComponent
        let destURL = booksDirectoryURL.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        let publication = try await ReadiumService.shared.openPublication(at: destURL)
        let parsed = EPUBParserService.shared.parseMetadata(from: destURL, publication: publication)

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
        defaults.removeObject(forKey: "highlights_\(book.id.uuidString)")
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

    // MARK: - Highlights

    func getHighlights(bookId: UUID) -> [BookHighlight] {
        guard let data = defaults.data(forKey: "highlights_\(bookId.uuidString)") else { return [] }
        return (try? JSONDecoder().decode([BookHighlight].self, from: data)) ?? []
    }

    func addHighlight(_ highlight: BookHighlight, bookId: UUID) {
        var highlights = getHighlights(bookId: bookId)
        highlights.append(highlight)
        saveHighlights(highlights, bookId: bookId)
    }

    func removeHighlight(id: UUID, bookId: UUID) {
        var highlights = getHighlights(bookId: bookId)
        highlights.removeAll { $0.id == id }
        saveHighlights(highlights, bookId: bookId)
    }

    func exportHighlightsMarkdown(bookTitle: String, bookId: UUID) -> String {
        let highlights = getHighlights(bookId: bookId)
        guard !highlights.isEmpty else { return "No highlights yet." }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var md = "# Highlights from \"\(bookTitle)\"\n\n"
        var currentChapter = ""
        for h in highlights {
            if h.chapterName != currentChapter {
                currentChapter = h.chapterName
                md += "## \(currentChapter)\n\n"
            }
            md += "> \(h.text)\n\n"
            md += "*\(formatter.string(from: h.dateCreated))*\n\n---\n\n"
        }
        return md
    }

    private func saveHighlights(_ highlights: [BookHighlight], bookId: UUID) {
        objectWillChange.send()
        if let data = try? JSONEncoder().encode(highlights) {
            defaults.set(data, forKey: "highlights_\(bookId.uuidString)")
        }
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
