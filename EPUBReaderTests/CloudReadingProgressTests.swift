import Combine
import XCTest
@testable import EPUBReader

private final class FakeCloudKeyValueStore: CloudReadingProgressKeyValueStore {
    var values: [String: String] = [:]
    var synchronizeCount = 0

    func string(forKey key: String) -> String? {
        values[key]
    }

    func set(_ value: String?, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}

@MainActor
final class CloudReadingProgressTests: XCTestCase {
    private var defaultsSuiteNames: [String] = []
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        for suiteName in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaultsSuiteNames.removeAll()
        cancellables.removeAll()
        super.tearDown()
    }

    func testStorageKeyMatchesSameBookNameAcrossImports() {
        let first = makeBook(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin", fileName: "left-hand.epub", contentFingerprint: "same")
        let second = makeBook(title: "  the left hand of darkness  ", author: "ursula k le guin", fileName: "renamed.epub", contentFingerprint: "same")
        let pdf = makeBook(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin", fileName: "left-hand.pdf", contentFingerprint: "same")

        XCTAssertEqual(CloudReadingProgress.storageKey(for: first), CloudReadingProgress.storageKey(for: second))
        XCTAssertNotEqual(CloudReadingProgress.storageKey(for: first), CloudReadingProgress.storageKey(for: pdf))
    }

    func testStorageKeyDisambiguatesSameTitleWithDifferentAuthors() {
        let firstAuthor = makeBook(title: "Selected Poems", author: "Author One", fileName: "selected.epub")
        let secondAuthor = makeBook(title: "Selected Poems", author: "Author Two", fileName: "selected-2.epub")

        XCTAssertNotEqual(CloudReadingProgress.storageKey(for: firstAuthor), CloudReadingProgress.storageKey(for: secondAuthor))
    }

    func testProgressFallsBackToSameBookNameWhenFingerprintsDiffer() {
        let first = makeBook(title: "Manual", author: "Unknown Author", fileName: "manual.epub", contentFingerprint: "abc")
        let second = makeBook(title: "Manual", author: "Unknown Author", fileName: "manual-copy.epub", contentFingerprint: "def")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)

        cloudStore.save(
            CloudReadingProgress(book: first, locatorJSONString: #"{"href":"chapter.xhtml"}"#, updatedAt: Date(timeIntervalSince1970: 100)),
            for: first
        )

        XCTAssertEqual(cloudStore.progress(for: second)?.locatorJSONString, #"{"href":"chapter.xhtml"}"#)
        XCTAssertEqual(cloudStore.progress(for: second)?.bookKey, CloudReadingProgress.bookKey(for: second))
    }

    func testContentFingerprintFramesDirectoryEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudReadingProgressTests.\(UUID().uuidString)")
        let first = root.appendingPathComponent("first.epub")
        let second = root.appendingPathComponent("second.epub")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data([0x62, 0x63, 0x00, 0x64]).write(to: first.appendingPathComponent("a"))
        try Data([0x62]).write(to: second.appendingPathComponent("a"))
        try Data([0x64]).write(to: second.appendingPathComponent("c"))

        XCTAssertNotEqual(
            try BookStore.contentFingerprint(for: first),
            try BookStore.contentFingerprint(for: second)
        )
    }

    func testCorruptCloudValueDecodesAsMissingProgress() {
        let book = makeBook(title: "Broken", fileName: "broken.epub")
        let fakeStore = FakeCloudKeyValueStore()
        fakeStore.set("not-json", forKey: CloudReadingProgress.storageKey(for: book))
        let store = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)

        XCTAssertNil(store.progress(for: book))
    }

    func testNewerCloudProgressIsJumpableAndStaleProgressIsIgnored() {
        let book = makeBook(title: "Progress", fileName: "progress.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(bookStore.newerCloudProgress(for: book))

        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 6, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )
        XCTAssertEqual(bookStore.newerCloudProgress(for: book)?.pageIndex, 6)

        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 0, updatedAt: Date(timeIntervalSince1970: 50)),
            for: book
        )
        XCTAssertNil(bookStore.newerCloudProgress(for: book))
    }

    func testSavingPDFPageWritesLocalAndCloudProgress() {
        let book = makeBook(title: "PDF", fileName: "pdf.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.savePDFPage(book: book, pageIndex: 2, updatedAt: Date(timeIntervalSince1970: 100))

        let progress = cloudStore.progress(for: book)
        XCTAssertEqual(bookStore.getPDFPage(bookId: book.id), 2)
        XCTAssertEqual(progress?.pageIndex, 2)
        XCTAssertEqual(progress?.displayPage, 3)
        XCTAssertEqual(progress?.format, .pdf)
    }

    func testSavingCloudProgressPublishesBookStoreChange() async {
        let book = makeBook(title: "Published PDF", fileName: "published.pdf")
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: CloudReadingProgressStore(store: FakeCloudKeyValueStore(), notificationObject: nil),
            notificationCenter: NotificationCenter()
        )
        let changed = expectation(description: "book store publishes local cloud progress changes")
        bookStore.objectWillChange
            .sink { changed.fulfill() }
            .store(in: &cancellables)

        bookStore.savePDFPage(book: book, pageIndex: 2, updatedAt: Date(timeIntervalSince1970: 100))

        await fulfillment(of: [changed], timeout: 1)
    }

    func testPassiveLocalSaveDoesNotOverwriteNewerRemoteProgress() {
        let book = makeBook(title: "Conflict", fileName: "conflict.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 100))
        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 6, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        bookStore.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(bookStore.getPDFPage(bookId: book.id), 1)
        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 6)
        XCTAssertEqual(bookStore.newerCloudProgress(for: book)?.pageIndex, 6)
    }

    func testLocalMovementAfterRemoteProgressCanBecomeNewCloudProgress() {
        let book = makeBook(title: "Keep Reading", fileName: "keep-reading.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 100))
        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 6, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        bookStore.savePDFPage(book: book, pageIndex: 2, updatedAt: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 2)
        XCTAssertNil(bookStore.newerCloudProgress(for: book))
    }

    func testInitialPassiveSaveDoesNotHideExistingRemoteProgress() {
        let book = makeBook(title: "Initial Remote", fileName: "initial.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 9, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        bookStore.savePDFPage(book: book, pageIndex: 0, updatedAt: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 9)
        XCTAssertEqual(bookStore.newerCloudProgress(for: book)?.pageIndex, 9)

        bookStore.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 1)
    }

    func testPassiveEPUBLocatorDoesNotOverwriteNewerRemoteProgress() {
        let book = makeBook(title: "Passive EPUB", fileName: "passive.epub")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.saveEPUBLocator(
            book: book,
            locatorJSONString: #"{"href":"chapter-1.xhtml"}"#,
            displayPage: 1,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        cloudStore.save(
            CloudReadingProgress(
                book: book,
                locatorJSONString: #"{"href":"chapter-9.xhtml"}"#,
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            for: book
        )

        bookStore.saveEPUBLocator(
            book: book,
            locatorJSONString: #"{"href":"chapter-2.xhtml"}"#,
            displayPage: 2,
            updatedAt: Date(timeIntervalSince1970: 300),
            allowReplacingNewerRemote: false
        )

        XCTAssertEqual(cloudStore.progress(for: book)?.locatorJSONString, #"{"href":"chapter-9.xhtml"}"#)
        XCTAssertEqual(bookStore.newerCloudProgress(for: book)?.locatorJSONString, #"{"href":"chapter-9.xhtml"}"#)
    }

    func testAllowedEPUBLocatorCanOverwriteNewerRemoteProgress() {
        let book = makeBook(title: "Manual EPUB", fileName: "manual.epub")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.saveEPUBLocator(
            book: book,
            locatorJSONString: #"{"href":"chapter-1.xhtml"}"#,
            displayPage: 1,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        cloudStore.save(
            CloudReadingProgress(
                book: book,
                locatorJSONString: #"{"href":"chapter-9.xhtml"}"#,
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            for: book
        )

        bookStore.saveEPUBLocator(
            book: book,
            locatorJSONString: #"{"href":"chapter-2.xhtml"}"#,
            displayPage: 2,
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(cloudStore.progress(for: book)?.locatorJSONString, #"{"href":"chapter-2.xhtml"}"#)
        XCTAssertNil(bookStore.newerCloudProgress(for: book))
    }

    func testPlaybackPositionCanOverwriteNewerRemoteProgress() {
        let book = makeBook(title: "Active EPUB", fileName: "active.epub")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.saveReadingPosition(
            book: book,
            position: ReadingPosition(chapterIndex: 0, paragraphIndex: 0, globalWordIndex: 1),
            locatorJSONString: #"{"href":"chapter-1.xhtml"}"#,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        cloudStore.save(
            CloudReadingProgress(
                book: book,
                locatorJSONString: #"{"href":"chapter-9.xhtml"}"#,
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            for: book
        )

        bookStore.saveReadingPosition(
            book: book,
            position: ReadingPosition(chapterIndex: 0, paragraphIndex: 1, globalWordIndex: 20),
            locatorJSONString: #"{"href":"chapter-2.xhtml"}"#,
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(cloudStore.progress(for: book)?.locatorJSONString, #"{"href":"chapter-2.xhtml"}"#)
        XCTAssertEqual(cloudStore.progress(for: book)?.readingPosition?.globalWordIndex, 20)
    }

    func testStaleRemoteProgressIsRepairedByNewerLocalProgress() {
        let book = makeBook(title: "Stale Remote", fileName: "stale.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )

        bookStore.savePDFPage(book: book, pageIndex: 3, updatedAt: Date(timeIntervalSince1970: 300))
        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 9, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        bookStore.savePDFPage(book: book, pageIndex: 3, updatedAt: Date(timeIntervalSince1970: 400))

        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 3)
        XCTAssertNil(bookStore.newerCloudProgress(for: book))
    }

    func testLegacyPDFProgressIsLocalBaselineBeforeRemoteJump() {
        let defaults = makeDefaults()
        let book = makeBook(title: "Legacy PDF", fileName: "legacy.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: defaults,
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        bookStore.savePDFPage(bookId: book.id, pageIndex: 3)
        cloudStore.save(
            CloudReadingProgress(book: book, pageIndex: 9, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        XCTAssertNil(bookStore.newerCloudProgress(for: book))

        bookStore.savePDFPage(book: book, pageIndex: 3, updatedAt: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 9)

        bookStore.savePDFPage(book: book, pageIndex: 4, updatedAt: Date(timeIntervalSince1970: 1_200))
        XCTAssertEqual(cloudStore.progress(for: book)?.pageIndex, 4)
    }

    func testLegacyEPUBProgressIsLocalBaselineBeforeRemoteJump() {
        let defaults = makeDefaults()
        let book = makeBook(title: "Legacy EPUB", fileName: "legacy.epub")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: defaults,
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter(),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let position = ReadingPosition(chapterIndex: 0, paragraphIndex: 2, globalWordIndex: 8)
        let locator = #"{"href":"chapter-1.xhtml"}"#

        defaults.set(locator, forKey: "locator_\(book.id.uuidString)")
        bookStore.saveReadingPosition(bookId: book.id, position: position)
        cloudStore.save(
            CloudReadingProgress(book: book, locatorJSONString: #"{"href":"chapter-9.xhtml"}"#, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        XCTAssertNil(bookStore.newerCloudProgress(for: book))

        bookStore.saveEPUBLocator(book: book, locatorJSONString: locator, displayPage: nil, updatedAt: Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(cloudStore.progress(for: book)?.locatorJSONString, #"{"href":"chapter-9.xhtml"}"#)

        bookStore.saveEPUBLocator(book: book, locatorJSONString: #"{"href":"chapter-2.xhtml"}"#, displayPage: nil, updatedAt: Date(timeIntervalSince1970: 1_200))
        XCTAssertEqual(cloudStore.progress(for: book)?.locatorJSONString, #"{"href":"chapter-2.xhtml"}"#)
    }

    func testPageAndLocatorOnlyUpdatesDoNotCarryStalePlaybackPosition() {
        let pdf = makeBook(title: "PDF Position", fileName: "position.pdf")
        let epub = makeBook(title: "EPUB Position", fileName: "position.epub")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )
        let oldPosition = ReadingPosition(chapterIndex: 0, paragraphIndex: 1, globalWordIndex: 5)

        bookStore.saveReadingPosition(
            book: pdf,
            position: oldPosition,
            pageIndex: 1,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        bookStore.savePDFPage(book: pdf, pageIndex: 4, updatedAt: Date(timeIntervalSince1970: 110))

        let pdfProgress = cloudStore.progress(for: pdf)
        XCTAssertEqual(pdfProgress?.pageIndex, 4)
        XCTAssertNil(pdfProgress?.readingPosition)

        bookStore.saveReadingPosition(
            book: epub,
            position: oldPosition,
            locatorJSONString: #"{"href":"chapter-1.xhtml"}"#,
            displayPage: 4,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        bookStore.saveEPUBLocator(
            book: epub,
            locatorJSONString: #"{"href":"chapter-2.xhtml"}"#,
            displayPage: 9,
            updatedAt: Date(timeIntervalSince1970: 110)
        )

        let epubProgress = cloudStore.progress(for: epub)
        XCTAssertEqual(epubProgress?.locatorJSONString, #"{"href":"chapter-2.xhtml"}"#)
        XCTAssertEqual(epubProgress?.displayPage, 9)
        XCTAssertNil(epubProgress?.readingPosition)
    }

    func testPDFReadingPositionWithoutTrustedPageKeepsManualPageProgress() {
        let book = makeBook(title: "PDF Manual Page", fileName: "manual-page.pdf")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )
        let stalePosition = ReadingPosition(chapterIndex: 0, paragraphIndex: 0, globalWordIndex: 0)

        bookStore.savePDFPage(book: book, pageIndex: 5, updatedAt: Date(timeIntervalSince1970: 100))
        bookStore.saveReadingPosition(
            book: book,
            position: stalePosition,
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        let progress = cloudStore.progress(for: book)
        XCTAssertEqual(progress?.pageIndex, 5)
        XCTAssertEqual(progress?.displayPage, 6)
        XCTAssertEqual(progress?.readingPosition, stalePosition)
    }

    func testSavingEPUBLocatorAndPositionWritesCloudProgress() {
        let book = makeBook(title: "EPUB", fileName: "epub.epub")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )
        let position = ReadingPosition(chapterIndex: 1, paragraphIndex: 3, globalWordIndex: 42)

        bookStore.saveEPUBLocator(
            book: book,
            locatorJSONString: #"{"href":"chapter.xhtml"}"#,
            displayPage: 8,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        bookStore.saveReadingPosition(
            book: book,
            position: position,
            locatorJSONString: #"{"href":"chapter.xhtml"}"#,
            updatedAt: Date(timeIntervalSince1970: 110)
        )

        let progress = cloudStore.progress(for: book)
        XCTAssertEqual(bookStore.getEPUBLocatorJSONString(bookId: book.id), #"{"href":"chapter.xhtml"}"#)
        XCTAssertEqual(bookStore.getReadingPosition(bookId: book.id), position)
        XCTAssertEqual(progress?.locatorJSONString, #"{"href":"chapter.xhtml"}"#)
        XCTAssertEqual(progress?.readingPosition, position)
        XCTAssertEqual(progress?.displayPage, 8)
        XCTAssertEqual(progress?.format, .epub)
    }

    func testMigratingFingerprintCopiesLegacyCloudProgressKey() {
        let id = UUID()
        let oldBook = makeBook(id: id, title: "Migrated", fileName: "migrated.epub")
        let newBook = makeBook(id: id, title: "Migrated", fileName: "migrated.epub", contentFingerprint: "abc")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)

        cloudStore.save(
            CloudReadingProgress(book: oldBook, locatorJSONString: #"{"href":"chapter-3.xhtml"}"#, updatedAt: Date(timeIntervalSince1970: 100)),
            for: oldBook
        )
        cloudStore.migrateProgress(from: oldBook, to: newBook)

        XCTAssertEqual(cloudStore.progress(for: newBook)?.locatorJSONString, #"{"href":"chapter-3.xhtml"}"#)
        XCTAssertEqual(cloudStore.progress(for: oldBook)?.locatorJSONString, #"{"href":"chapter-3.xhtml"}"#)
    }

    func testCloudSavesUseBackfilledMetadataForStaleBookValues() {
        let id = UUID()
        let oldBook = makeBook(id: id, title: "Backfilled", fileName: "backfilled.pdf")
        let newBook = makeBook(id: id, title: "Backfilled", fileName: "backfilled.pdf", contentFingerprint: "abc")
        let fakeStore = FakeCloudKeyValueStore()
        let cloudStore = CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore)
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: cloudStore,
            notificationCenter: NotificationCenter()
        )
        bookStore.books = [newBook]

        bookStore.savePDFPage(book: oldBook, pageIndex: 5, updatedAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(cloudStore.progress(for: newBook)?.pageIndex, 5)
        XCTAssertEqual(cloudStore.progress(for: newBook)?.bookKey, CloudReadingProgress.bookKey(for: newBook))
        XCTAssertEqual(cloudStore.progress(for: oldBook)?.pageIndex, 5)
    }

    func testExternalCloudNotificationPublishesBookStoreChange() async {
        let fakeStore = FakeCloudKeyValueStore()
        let notificationCenter = NotificationCenter()
        let bookStore = BookStore(
            defaults: makeDefaults(),
            cloudProgressStore: CloudReadingProgressStore(store: fakeStore, notificationObject: fakeStore),
            notificationCenter: notificationCenter
        )
        let changed = expectation(description: "book store publishes cloud progress change")
        bookStore.objectWillChange
            .sink { changed.fulfill() }
            .store(in: &cancellables)

        notificationCenter.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: fakeStore
        )

        await fulfillment(of: [changed], timeout: 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CloudReadingProgressTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        return UserDefaults(suiteName: suiteName)!
    }

    private func makeBook(
        id: UUID = UUID(),
        title: String,
        author: String = "Author",
        fileName: String,
        contentFingerprint: String? = nil
    ) -> BookMetadata {
        BookMetadata(
            id: id,
            title: title,
            author: author,
            fileName: fileName,
            dateAdded: Date(timeIntervalSince1970: 0),
            contentFingerprint: contentFingerprint
        )
    }
}
