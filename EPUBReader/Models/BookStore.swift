import CryptoKit
import SwiftUI

@MainActor
class BookStore: ObservableObject {
    @Published var books: [BookMetadata] = []

    private let defaults = UserDefaults.standard
    private let readingProgressSyncService = ReadingProgressSyncService()
    private var pendingSyncTasks: [String: Task<Void, Never>] = [:]
    private let booksDirectoryURL: URL
    private let metadataFileURL: URL

    var ttsProvider: TTSProviderType {
        get { TTSProviderType(rawValue: defaults.string(forKey: "ttsProvider") ?? "") ?? .elevenLabs }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: "ttsProvider") }
    }

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

    var cloudSyncEndpoint: String {
        get { defaults.string(forKey: "cloudSyncEndpoint") ?? "" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "cloudSyncEndpoint")
        }
    }

    var cloudSyncSecret: String {
        get { defaults.string(forKey: "cloudSyncSecret") ?? "" }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "cloudSyncSecret")
        }
    }

    var cloudSyncStatus: String {
        readingProgressSyncConfiguration == nil ? "Disabled" : "Configured"
    }

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
            let value = defaults.double(forKey: "playbackSpeed")
            return value > 0 ? value : 1.0
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "playbackSpeed") }
    }

    var fontSize: Double {
        get {
            let value = defaults.double(forKey: "readerFontSize")
            return value > 0 ? value : 17.0
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
            dateAdded: Date(),
            syncIdentifier: makeSyncIdentifier(fileURL: destURL, fallbackSeed: fileName)
        )

        books.insert(book, at: 0)
        saveBooks()
        return book
    }

    func removeBook(_ book: BookMetadata) {
        let syncIdentifier = resolvedSyncIdentifier(for: book)
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: book.fileURL)
        defaults.removeObject(forKey: legacyPositionKey(book.id))
        defaults.removeObject(forKey: legacyLocatorKey(book.id))
        defaults.removeObject(forKey: legacyHighlightsKey(book.id))
        defaults.removeObject(forKey: readingStateKey(syncIdentifier: syncIdentifier))
        pendingSyncTasks[syncIdentifier]?.cancel()
        pendingSyncTasks.removeValue(forKey: syncIdentifier)
        saveBooks()
    }

    func readingState(for book: BookMetadata) async -> ReadingStateRecord? {
        let syncIdentifier = resolvedSyncIdentifier(for: book)
        let localState = localReadingState(for: book, syncIdentifier: syncIdentifier)

        guard let configuration = readingProgressSyncConfiguration else {
            return localState
        }

        do {
            let remoteState = try await readingProgressSyncService.fetchReadingState(
                syncIdentifier: syncIdentifier,
                configuration: configuration
            )
            let newestState = ReadingStateRecord.newest(local: localState, remote: remoteState)

            if let newestState, newestState != localState {
                saveLocalReadingState(newestState, syncIdentifier: syncIdentifier)
            }

            if let newestState, newestState != remoteState {
                scheduleCloudSync(for: syncIdentifier, state: newestState)
            }

            return newestState
        } catch {
            return localState
        }
    }

    func getReadingPosition(book: BookMetadata) -> ReadingPosition? {
        localReadingState(for: book, syncIdentifier: resolvedSyncIdentifier(for: book))?.position
    }

    func getSavedLocatorJSON(book: BookMetadata) -> String? {
        localReadingState(for: book, syncIdentifier: resolvedSyncIdentifier(for: book))?.locatorJSON
    }

    func saveReadingPosition(book: BookMetadata, position: ReadingPosition) {
        updateReadingState(for: book) { state in
            state.position = position
        }
    }

    func saveLocator(book: BookMetadata, locatorJSONString: String) {
        updateReadingState(for: book) { state in
            state.locatorJSON = locatorJSONString
        }
    }

    func getHighlights(bookId: UUID) -> [BookHighlight] {
        guard let data = defaults.data(forKey: legacyHighlightsKey(bookId)) else { return [] }
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

        var markdown = "# Highlights from \"\(bookTitle)\"\n\n"
        var currentChapter = ""

        for highlight in highlights {
            if highlight.chapterName != currentChapter {
                currentChapter = highlight.chapterName
                markdown += "## \(currentChapter)\n\n"
            }
            markdown += "> \(highlight.text)\n\n"
            markdown += "*\(formatter.string(from: highlight.dateCreated))*\n\n---\n\n"
        }

        return markdown
    }

    private var readingProgressSyncConfiguration: ReadingProgressSyncConfiguration? {
        let trimmedEndpoint = cloudSyncEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = cloudSyncSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedEndpoint.isEmpty, !trimmedSecret.isEmpty else { return nil }

        let normalizedEndpoint: String
        if trimmedEndpoint.contains("://") {
            normalizedEndpoint = trimmedEndpoint
        } else {
            normalizedEndpoint = "https://\(trimmedEndpoint)"
        }

        guard let endpoint = URL(string: normalizedEndpoint) else { return nil }
        return ReadingProgressSyncConfiguration(endpoint: endpoint, secret: trimmedSecret)
    }

    private func updateReadingState(
        for book: BookMetadata,
        mutate: (inout ReadingStateRecord) -> Void
    ) {
        let syncIdentifier = resolvedSyncIdentifier(for: book)
        var state = localReadingState(for: book, syncIdentifier: syncIdentifier) ?? ReadingStateRecord(
            position: nil,
            locatorJSON: nil,
            updatedAt: ReadingStateRecord.nowTimestamp()
        )
        mutate(&state)
        state.updatedAt = ReadingStateRecord.nowTimestamp()
        saveLocalReadingState(state, syncIdentifier: syncIdentifier)
        scheduleCloudSync(for: syncIdentifier, state: state)
    }

    private func localReadingState(
        for book: BookMetadata,
        syncIdentifier: String
    ) -> ReadingStateRecord? {
        if let data = defaults.data(forKey: readingStateKey(syncIdentifier: syncIdentifier)),
           let state = try? JSONDecoder().decode(ReadingStateRecord.self, from: data) {
            return state
        }

        let legacyPositionData = defaults.data(forKey: legacyPositionKey(book.id))
        let legacyLocator = defaults.string(forKey: legacyLocatorKey(book.id))

        guard legacyPositionData != nil || legacyLocator != nil else { return nil }

        let legacyPosition = legacyPositionData.flatMap {
            try? JSONDecoder().decode(ReadingPosition.self, from: $0)
        }
        let migratedState = ReadingStateRecord(
            position: legacyPosition,
            locatorJSON: legacyLocator,
            updatedAt: ReadingStateRecord.nowTimestamp()
        )

        saveLocalReadingState(migratedState, syncIdentifier: syncIdentifier)
        return migratedState
    }

    private func saveLocalReadingState(
        _ state: ReadingStateRecord,
        syncIdentifier: String
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: readingStateKey(syncIdentifier: syncIdentifier))
    }

    private func scheduleCloudSync(
        for syncIdentifier: String,
        state: ReadingStateRecord
    ) {
        guard let configuration = readingProgressSyncConfiguration else { return }

        pendingSyncTasks[syncIdentifier]?.cancel()
        pendingSyncTasks[syncIdentifier] = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? await readingProgressSyncService.pushReadingState(
                state,
                syncIdentifier: syncIdentifier,
                configuration: configuration
            )
        }
    }

    private func resolvedSyncIdentifier(for book: BookMetadata) -> String {
        if let existing = book.syncIdentifier, !existing.isEmpty {
            return existing
        }

        if let stored = books.first(where: { $0.id == book.id })?.syncIdentifier, !stored.isEmpty {
            return stored
        }

        let computed = makeSyncIdentifier(
            fileURL: book.fileURL,
            fallbackSeed: "\(book.fileName)|\(book.title)|\(book.author)"
        )
        persistSyncIdentifier(computed, for: book.id)
        return computed
    }

    private func persistSyncIdentifier(_ syncIdentifier: String, for bookID: UUID) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        guard books[index].syncIdentifier != syncIdentifier else { return }
        books[index].syncIdentifier = syncIdentifier
        saveBooks()
    }

    private func makeSyncIdentifier(fileURL: URL, fallbackSeed: String) -> String {
        if let data = try? Data(contentsOf: fileURL) {
            return SHA256.hash(data: data).hexDigest
        }
        return SHA256.hash(data: Data(fallbackSeed.utf8)).hexDigest
    }

    private func saveHighlights(_ highlights: [BookHighlight], bookId: UUID) {
        objectWillChange.send()
        if let data = try? JSONEncoder().encode(highlights) {
            defaults.set(data, forKey: legacyHighlightsKey(bookId))
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

    private func readingStateKey(syncIdentifier: String) -> String {
        "readingState_\(syncIdentifier)"
    }

    private func legacyPositionKey(_ bookId: UUID) -> String {
        "position_\(bookId.uuidString)"
    }

    private func legacyLocatorKey(_ bookId: UUID) -> String {
        "locator_\(bookId.uuidString)"
    }

    private func legacyHighlightsKey(_ bookId: UUID) -> String {
        "highlights_\(bookId.uuidString)"
    }
}

private extension SHA256Digest {
    var hexDigest: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
