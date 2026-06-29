import CryptoKit
import SwiftUI
import PDFKit
import ReadiumShared

@MainActor
class BookStore: ObservableObject {
    @Published var books: [BookMetadata] = []

    private let defaults: UserDefaults
    private let cloudProgressStore: CloudReadingProgressStore
    private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var cloudProgressObserver: NSObjectProtocol?

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

    /// Speech-driven page following for EPUBs. (Historic key — kept so the EPUB setting
    /// survives the split into a separate PDF toggle.)
    var autoAdvancePagesWithSpeech: Bool {
        get {
            defaults.object(forKey: "autoAdvancePagesWithSpeech") as? Bool ?? true
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "autoAdvancePagesWithSpeech") }
    }

    /// Speech-driven page following for PDFs, controlled independently of the EPUB toggle.
    /// On first run after the split it inherits the pre-split combined value so a user who
    /// had narration auto-advance turned off doesn't get it silently re-enabled for PDFs.
    var autoAdvancePagesWithSpeechInPDF: Bool {
        get {
            defaults.object(forKey: "autoAdvancePagesWithSpeechInPDF") as? Bool
                ?? autoAdvancePagesWithSpeech
        }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "autoAdvancePagesWithSpeechInPDF") }
    }

    var readerTheme: ReaderTheme {
        get { ReaderTheme(rawValue: defaults.string(forKey: "readerTheme") ?? "system") ?? .system }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: "readerTheme") }
    }

    private let booksDirectoryURL: URL
    private let metadataFileURL: URL

    init(
        defaults: UserDefaults = .standard,
        cloudProgressStore: CloudReadingProgressStore = CloudReadingProgressStore(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.cloudProgressStore = cloudProgressStore
        self.notificationCenter = notificationCenter

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectoryURL = docs.appendingPathComponent("Books")
        metadataFileURL = docs.appendingPathComponent("books_metadata.json")

        try? FileManager.default.createDirectory(at: booksDirectoryURL, withIntermediateDirectories: true)
        cloudProgressStore.synchronize()
        observeCloudProgressChanges()
        loadBooks()
        scheduleContentFingerprintBackfill()
    }

    deinit {
        if let cloudProgressObserver {
            notificationCenter.removeObserver(cloudProgressObserver)
        }
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
        let pdfPageCount: Int?
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
            pdfPageCount = document.pageCount > 0 ? document.pageCount : nil
        case .epub:
            let publication = try await ReadiumService.shared.openPublication(at: stagedURL)
            let parsed = EPUBParserService.shared.parseMetadata(from: stagedURL, publication: publication)
            title = parsed.title
            author = parsed.author
            pdfPageCount = nil
        }

        let contentFingerprint = try? Self.contentFingerprint(for: stagedURL)
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
            dateAdded: Date(),
            contentFingerprint: contentFingerprint
        )

        books.insert(book, at: 0)
        saveBooks()
        if let pdfPageCount {
            setCachedPDFPageCount(pdfPageCount, bookId: book.id)
        }
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

    /// Creates a stable identifier for the imported bytes so cloud progress does not rely only on metadata.
    nonisolated static func contentFingerprint(for url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }

        var hasher = SHA256()
        if isDirectory.boolValue {
            let files = try regularFiles(in: url)
            for file in files {
                hasher.update(data: Data(file.relativePath.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: try Data(contentsOf: file.url, options: .mappedIfSafe))
                hasher.update(data: Data([0]))
            }
        } else {
            hasher.update(data: try Data(contentsOf: url, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func regularFiles(in directory: URL) throws -> [(relativePath: String, url: URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(relativePath: String, url: URL)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(url.path.dropFirst(directory.path.count + 1))
            files.append((relativePath, url))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    func removeBook(_ book: BookMetadata) {
        let currentBook = currentBookMetadata(for: book)
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: currentBook.fileURL)
        defaults.removeObject(forKey: "position_\(currentBook.id.uuidString)")
        defaults.removeObject(forKey: "highlights_\(currentBook.id.uuidString)")
        defaults.removeObject(forKey: "pdfPage_\(currentBook.id.uuidString)")
        defaults.removeObject(forKey: "pdfPageCount_\(currentBook.id.uuidString)")
        defaults.removeObject(forKey: "locator_\(currentBook.id.uuidString)")
        defaults.removeObject(forKey: "cloudProgress_\(currentBook.id.uuidString)")
        defaults.removeObject(forKey: legacyCloudProgressBaselineKey(bookId: currentBook.id))
        saveBooks()
    }

    func savePDFPage(bookId: UUID, pageIndex: Int) {
        defaults.set(pageIndex, forKey: "pdfPage_\(bookId.uuidString)")
    }

    func savePDFPage(book: BookMetadata, pageIndex: Int, updatedAt: Date = Date()) {
        let currentBook = currentBookMetadata(for: book)
        let baseline = localCloudProgressSnapshot(for: currentBook, backfillLegacy: true)
        savePDFPage(bookId: currentBook.id, pageIndex: pageIndex)
        let progress = mergedCloudProgress(
            for: currentBook,
            existing: baseline?.progress,
            pageIndex: pageIndex,
            displayPage: pageIndex + 1,
            updatedAt: updatedAt
        )
        saveCloudProgress(progress, for: currentBook, baseline: baseline)
    }

    func getPDFPage(bookId: UUID) -> Int? {
        defaults.object(forKey: "pdfPage_\(bookId.uuidString)") as? Int
    }

    func saveReadingPosition(bookId: UUID, position: ReadingPosition) {
        if let data = try? JSONEncoder().encode(position) {
            defaults.set(data, forKey: "position_\(bookId.uuidString)")
        }
    }

    func saveReadingPosition(
        book: BookMetadata,
        position: ReadingPosition,
        locatorJSONString: String? = nil,
        pageIndex: Int? = nil,
        displayPage: Int? = nil,
        updatedAt: Date = Date()
    ) {
        let currentBook = currentBookMetadata(for: book)
        let baseline = localCloudProgressSnapshot(for: currentBook, backfillLegacy: true)
        saveReadingPosition(bookId: currentBook.id, position: position)
        guard pageIndex != nil || locatorJSONString != nil else { return }
        let progress = mergedCloudProgress(
            for: currentBook,
            existing: baseline?.progress,
            pageIndex: pageIndex,
            displayPage: displayPage ?? pageIndex.map { $0 + 1 },
            locatorJSONString: locatorJSONString,
            readingPosition: position,
            updatedAt: updatedAt
        )
        saveCloudProgress(progress, for: currentBook, baseline: baseline)
    }

    func getReadingPosition(bookId: UUID) -> ReadingPosition? {
        guard let data = defaults.data(forKey: "position_\(bookId.uuidString)") else { return nil }
        return try? JSONDecoder().decode(ReadingPosition.self, from: data)
    }

    func saveEPUBLocator(
        book: BookMetadata,
        locatorJSONString: String,
        displayPage: Int?,
        updatedAt: Date = Date(),
        allowReplacingNewerRemote: Bool = true
    ) {
        let currentBook = currentBookMetadata(for: book)
        let baseline = localCloudProgressSnapshot(for: currentBook, backfillLegacy: true)
        defaults.set(locatorJSONString, forKey: "locator_\(currentBook.id.uuidString)")
        let progress = mergedCloudProgress(
            for: currentBook,
            existing: baseline?.progress,
            displayPage: displayPage,
            locatorJSONString: locatorJSONString,
            updatedAt: updatedAt
        )
        saveCloudProgress(
            progress,
            for: currentBook,
            baseline: baseline,
            allowReplacingNewerRemote: allowReplacingNewerRemote
        )
    }

    func getEPUBLocatorJSONString(bookId: UUID) -> String? {
        defaults.string(forKey: "locator_\(bookId.uuidString)")
    }

    // MARK: - Reading progress (Library indicator)

    /// Best-effort whole-book reading progress (0...1) for the Library row indicator.
    /// EPUB resolves synchronously from the saved locator's `totalProgression`; PDF needs
    /// the document's page count, which is loaded once off the main actor and cached.
    /// Returns nil when the book hasn't been opened or progress can't be determined.
    func progressFraction(for book: BookMetadata) async -> Double? {
        let currentBook = currentBookMetadata(for: book)
        switch currentBook.format {
        case .epub:
            return ReadingProgress.fraction(epubLocatorJSON: getEPUBLocatorJSONString(bookId: currentBook.id))
        case .pdf:
            guard let pageIndex = getPDFPage(bookId: currentBook.id) else { return nil }
            let pageCount: Int?
            if let cached = cachedPDFPageCount(bookId: currentBook.id) {
                pageCount = cached
            } else {
                pageCount = await resolvePDFPageCount(for: currentBook)
            }
            return ReadingProgress.fraction(pdfPageIndex: pageIndex, pageCount: pageCount)
        }
    }

    private func resolvePDFPageCount(for book: BookMetadata) async -> Int? {
        guard let count = await Self.loadPDFPageCount(at: book.fileURL) else { return nil }
        setCachedPDFPageCount(count, bookId: book.id)
        return count
    }

    private func cachedPDFPageCount(bookId: UUID) -> Int? {
        defaults.object(forKey: "pdfPageCount_\(bookId.uuidString)") as? Int
    }

    private func setCachedPDFPageCount(_ count: Int, bookId: UUID) {
        defaults.set(count, forKey: "pdfPageCount_\(bookId.uuidString)")
    }

    /// Reads a PDF's page count off the main actor — `PDFDocument` parsing can touch disk,
    /// and only the resulting `Int` crosses back, so the non-Sendable document never escapes.
    nonisolated static func loadPDFPageCount(at url: URL) async -> Int? {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url) else { return nil }
            let count = document.pageCount
            return count > 0 ? count : nil
        }.value
    }

    func newerCloudProgress(for book: BookMetadata) -> CloudReadingProgress? {
        let currentBook = currentBookMetadata(for: book)
        guard let remote = cloudProgressStore.progress(for: currentBook),
              remote.isNewer(than: localCloudProgressSnapshot(for: currentBook, backfillLegacy: false)?.progress) else {
            return nil
        }
        return remote
    }

    func applyCloudProgressLocally(_ progress: CloudReadingProgress, for book: BookMetadata) {
        let currentBook = currentBookMetadata(for: book)
        guard CloudReadingProgress.matches(progress, book: currentBook),
              progress.format == currentBook.format else { return }

        let local = localProgressForApply(progress, bookId: currentBook.id)
        if let pageIndex = local.pageIndex {
            savePDFPage(bookId: currentBook.id, pageIndex: pageIndex)
        }
        if let position = local.readingPosition {
            saveReadingPosition(bookId: currentBook.id, position: position)
        }
        if let locatorJSONString = local.locatorJSONString {
            defaults.set(locatorJSONString, forKey: "locator_\(currentBook.id.uuidString)")
        }
        saveLocalCloudProgress(local, bookId: currentBook.id)
        objectWillChange.send()
    }

    private func observeCloudProgressChanges() {
        cloudProgressObserver = notificationCenter.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudProgressStore.notificationObject,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    private func mergedCloudProgress(
        for book: BookMetadata,
        existing: CloudReadingProgress? = nil,
        pageIndex: Int? = nil,
        displayPage: Int? = nil,
        locatorJSONString: String? = nil,
        readingPosition: ReadingPosition? = nil,
        updatedAt: Date
    ) -> CloudReadingProgress {
        let existing = existing ?? localCloudProgressSnapshot(for: book, backfillLegacy: false)?.progress
        return CloudReadingProgress(
            book: book,
            pageIndex: pageIndex ?? existing?.pageIndex,
            displayPage: displayPage ?? existing?.displayPage,
            locatorJSONString: locatorJSONString ?? existing?.locatorJSONString,
            readingPosition: readingPosition,
            updatedAt: updatedAt
        )
    }

    /// Writes local progress to iCloud without letting passive stale callbacks overwrite newer remote progress.
    private func saveCloudProgress(
        _ progress: CloudReadingProgress,
        for book: BookMetadata,
        baseline: LocalCloudProgressSnapshot?,
        allowReplacingNewerRemote: Bool = true
    ) {
        let remote = cloudProgressStore.progress(for: book)
        let snapshot = baseline
        let local = snapshot?.progress
        let locationChanged = progressLocationChanged(progress, from: local)

        if let remote,
           remote.isNewer(than: local),
           progress.readingPosition == nil,
           remote.readingPosition != nil,
           isSameCloudLocation(progress, remote) {
            return
        }

        let progressToSave = progressPreservingRemoteReadingPosition(progress, remote: remote, book: book)

        if let remote {
            if local == nil {
                saveLocalCloudProgress(progressToSave.withUpdatedAt(remote.updatedAt.addingTimeInterval(-0.001)), bookId: book.id)
                objectWillChange.send()
                return
            }
            if remote.isNewer(than: local), !allowReplacingNewerRemote {
                return
            }
            if !locationChanged,
               snapshot?.source == .legacy || remote.isNewer(than: local) {
                return
            }
        }

        saveLocalCloudProgress(progressToSave, bookId: book.id)
        cloudProgressStore.save(progressToSave, for: book)
        objectWillChange.send()
    }

    private func localProgressForApply(_ progress: CloudReadingProgress, bookId: UUID) -> CloudReadingProgress {
        guard let local = localCloudProgress(bookId: bookId),
              local.isNewer(than: progress),
              isSameCloudLocation(local, progress) else { return progress }

        if local.readingPosition == nil, let readingPosition = progress.readingPosition {
            return local.withReadingPosition(readingPosition)
        }
        return local
    }

    private func progressPreservingRemoteReadingPosition(
        _ progress: CloudReadingProgress,
        remote: CloudReadingProgress?,
        book: BookMetadata
    ) -> CloudReadingProgress {
        guard let remote,
              progress.readingPosition == nil,
              let readingPosition = remote.readingPosition,
              isSameCloudLocation(progress, remote) else { return progress }

        return CloudReadingProgress(
            book: book,
            pageIndex: progress.pageIndex,
            displayPage: progress.displayPage,
            locatorJSONString: progress.locatorJSONString,
            readingPosition: readingPosition,
            updatedAt: progress.updatedAt
        )
    }

    private func isSameCloudLocation(_ lhs: CloudReadingProgress, _ rhs: CloudReadingProgress) -> Bool {
        lhs.format == rhs.format
            && lhs.pageIndex == rhs.pageIndex
            && lhs.displayPage == rhs.displayPage
            && lhs.locatorJSONString == rhs.locatorJSONString
    }

    private func progressLocationChanged(_ progress: CloudReadingProgress, from local: CloudReadingProgress?) -> Bool {
        guard let local else { return false }
        let readingPositionChanged = progress.readingPosition.map { $0 != local.readingPosition } ?? false
        return progress.pageIndex != local.pageIndex
            || progress.displayPage != local.displayPage
            || progress.locatorJSONString != local.locatorJSONString
            || readingPositionChanged
    }

    private func localCloudProgress(bookId: UUID) -> CloudReadingProgress? {
        guard let data = defaults.data(forKey: "cloudProgress_\(bookId.uuidString)") else { return nil }
        return try? JSONDecoder().decode(CloudReadingProgress.self, from: data)
    }

    private enum LocalCloudProgressSource {
        case stored
        case legacy
    }

    private struct LocalCloudProgressSnapshot {
        let progress: CloudReadingProgress
        let source: LocalCloudProgressSource
    }

    private func localCloudProgressSnapshot(for book: BookMetadata, backfillLegacy: Bool) -> LocalCloudProgressSnapshot? {
        if let progress = localCloudProgress(bookId: book.id) {
            let source: LocalCloudProgressSource = defaults.bool(forKey: legacyCloudProgressBaselineKey(bookId: book.id)) ? .legacy : .stored
            return LocalCloudProgressSnapshot(progress: progress, source: source)
        }
        guard let progress = legacyCloudProgress(for: book) else { return nil }
        if backfillLegacy {
            saveLocalCloudProgress(progress, bookId: book.id, legacyBaseline: true)
        }
        return LocalCloudProgressSnapshot(progress: progress, source: .legacy)
    }

    private func legacyCloudProgress(for book: BookMetadata) -> CloudReadingProgress? {
        let pageIndex = getPDFPage(bookId: book.id)
        let locatorJSONString = getEPUBLocatorJSONString(bookId: book.id)
        let readingPosition = getReadingPosition(bookId: book.id)
        guard pageIndex != nil || locatorJSONString != nil || readingPosition != nil else { return nil }
        return CloudReadingProgress(
            book: book,
            pageIndex: pageIndex,
            locatorJSONString: locatorJSONString,
            readingPosition: readingPosition,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func saveLocalCloudProgress(_ progress: CloudReadingProgress, bookId: UUID, legacyBaseline: Bool = false) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: "cloudProgress_\(bookId.uuidString)")
        if legacyBaseline {
            defaults.set(true, forKey: legacyCloudProgressBaselineKey(bookId: bookId))
        } else {
            defaults.removeObject(forKey: legacyCloudProgressBaselineKey(bookId: bookId))
        }
    }

    private func legacyCloudProgressBaselineKey(bookId: UUID) -> String {
        "cloudProgressLegacyBaseline_\(bookId.uuidString)"
    }

    private func currentBookMetadata(for book: BookMetadata) -> BookMetadata {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return book }
        return books[index]
    }

    private func scheduleContentFingerprintBackfill() {
        let candidates = books
            .filter { $0.contentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
            .map { (id: $0.id, fileURL: $0.fileURL) }
        guard !candidates.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self, candidates] in
            let updates = candidates.compactMap { candidate -> (UUID, String)? in
                guard let fingerprint = try? Self.contentFingerprint(for: candidate.fileURL) else { return nil }
                return (candidate.id, fingerprint)
            }
            guard !updates.isEmpty else { return }
            await self?.applyContentFingerprintBackfill(updates)
        }
    }

    private func applyContentFingerprintBackfill(_ updates: [(UUID, String)]) {
        var changed = false
        for update in updates {
            guard let index = books.firstIndex(where: { $0.id == update.0 }),
                  books[index].contentFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { continue }
            books[index].contentFingerprint = update.1
            changed = true
        }
        if changed {
            saveBooks()
            objectWillChange.send()
        }
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
