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
        let first = makeBook(title: "The Left Hand of Darkness", fileName: "left-hand.epub")
        let second = makeBook(title: "  the left hand of darkness  ", fileName: "renamed.epub")
        let pdf = makeBook(title: "The Left Hand of Darkness", fileName: "left-hand.pdf")

        XCTAssertEqual(CloudReadingProgress.storageKey(for: first), CloudReadingProgress.storageKey(for: second))
        XCTAssertNotEqual(CloudReadingProgress.storageKey(for: first), CloudReadingProgress.storageKey(for: pdf))
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

    private func makeBook(title: String, fileName: String) -> BookMetadata {
        BookMetadata(
            id: UUID(),
            title: title,
            author: "Author",
            fileName: fileName,
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }
}
