import SwiftUI
import PDFKit
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

    var autoAdvancePagesWithSpeech: Bool {
        get {
            defaults.object(forKey: "autoAdvancePagesWithSpeech") as? Bool ?? true
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "autoAdvancePagesWithSpeech") }
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
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           !EPUBImport.isExplodedEPUBDirectory(sourceURL) {
            throw EPUBError.notAnEPUB
        }

        let fileName = availableFileName(for: sourceURL.lastPathComponent)

        // Stage in tmp and only install into Books/ after a successful parse:
        // a mid-copy or parse failure must never leave partial junk in Books/
        // or delete an existing same-named book's file.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        let stagedURL = stagingDir.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            // Detached: on the failure path this deletes a fully staged book,
            // which shouldn't hitch the main actor.
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stagingDir) }
        }

        try await Self.coordinatedCopy(from: sourceURL, to: stagedURL)

        let title: String?
        let author: String?
        switch BookFormat(fileName: fileName) {
        case .pdf:
            guard let document = PDFDocument(url: stagedURL) else {
                throw PDFError.invalidFile
            }
            guard !document.isLocked else {
                throw PDFError.passwordProtected
            }
            let parsed = PDFParserService.shared.parseMetadata(from: document)
            title = parsed.title
            author = parsed.author
        case .epub:
            let publication = try await ReadiumService.shared.openPublication(at: stagedURL)
            let parsed = EPUBParserService.shared.parseMetadata(from: stagedURL, publication: publication)
            title = parsed.title
            author = parsed.author
        }

        let destURL = booksDirectoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destURL)
        }

        let book = BookMetadata(
            id: UUID(),
            title: title ?? BookMetadata.fallbackTitle(forFileName: fileName),
            author: author ?? "Unknown Author",
            fileName: fileName,
            dateAdded: Date()
        )

        books.insert(book, at: 0)
        saveBooks()
        return book
    }

    /// Same-named imports get "name-2.epub"-style suffixes: Books/ entries
    /// are keyed by file name, so reusing one would cross-link two library
    /// entries to a single file (deleting either would orphan the other).
    private func availableFileName(for proposed: String) -> String {
        func taken(_ name: String) -> Bool { books.contains { $0.fileName == name } }
        guard taken(proposed) else { return proposed }
        let base = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        var n = 2
        func candidate(_ n: Int) -> String { ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)" }
        while taken(candidate(n)) { n += 1 }
        return candidate(n)
    }

    /// Coordinated read before copying picker items into the sandbox. The
    /// system materializes the coordinated item itself; folder children are
    /// best-effort (an evicted child fails the copy with a clear error and the
    /// user can retry after downloading in Files). Runs on a GCD queue because
    /// coordination blocks its thread — possibly for a long download — which
    /// neither the main actor nor the cooperative pool should absorb.
    nonisolated static func coordinatedCopy(from source: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var coordinatorError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { url in
                    do {
                        try FileManager.default.copyItem(at: url, to: destination)
                    } catch {
                        copyError = error
                    }
                }
                if let coordinatorError {
                    continuation.resume(throwing: coordinatorError)
                } else if let copyError {
                    continuation.resume(throwing: copyError)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removeBook(_ book: BookMetadata) {
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: book.fileURL)
        defaults.removeObject(forKey: "position_\(book.id.uuidString)")
        defaults.removeObject(forKey: "highlights_\(book.id.uuidString)")
        defaults.removeObject(forKey: "pdfPage_\(book.id.uuidString)")
        defaults.removeObject(forKey: "locator_\(book.id.uuidString)")
        saveBooks()
    }

    func savePDFPage(bookId: UUID, pageIndex: Int) {
        defaults.set(pageIndex, forKey: "pdfPage_\(bookId.uuidString)")
    }

    func getPDFPage(bookId: UUID) -> Int? {
        defaults.object(forKey: "pdfPage_\(bookId.uuidString)") as? Int
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
