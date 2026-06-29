import XCTest
@testable import EPUBReader

private final class FakeCloudKeyValueStore: CloudReadingProgressKeyValueStore {
    var values: [String: String] = [:]
    var synchronizeCount = 0

    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() -> Bool { synchronizeCount += 1; return true }
}

@MainActor
final class CloudSyncStatusTests: XCTestCase {
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for name in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    // MARK: - cloudSyncStatuses

    func testStatusesOmitBooksWithoutProgress() {
        let (store, _, _) = makeStore()
        store.books = [makeBook(title: "Untouched", fileName: "untouched.pdf")]

        XCTAssertTrue(store.cloudSyncStatuses().isEmpty)
    }

    func testStatusIsPendingUploadWhenLocalHasNoRemote() {
        let (store, cloud, _) = makeStore()
        let book = makeBook(title: "Local Only", fileName: "local.pdf")
        store.books = [book]

        store.savePDFPage(book: book, pageIndex: 4, updatedAt: Date(timeIntervalSince1970: 100))
        cloud.removeProgress(for: book) // simulate progress that never reached iCloud

        let statuses = store.cloudSyncStatuses()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses.first?.state, .pendingUpload)
        XCTAssertEqual(statuses.first?.pageLabel, "Page 5")
        XCTAssertEqual(statuses.first?.updatedAt, Date(timeIntervalSince1970: 100))
    }

    func testStatusIsUpdateAvailableWhenRemoteIsNewer() {
        let (store, cloud, _) = makeStore()
        let book = makeBook(title: "Remote Newer", fileName: "remote.pdf")
        store.books = [book]

        store.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 100))
        cloud.save(
            CloudReadingProgress(book: book, pageIndex: 9, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )

        let status = store.cloudSyncStatuses().first
        XCTAssertEqual(status?.state, .updateAvailable)
        XCTAssertEqual(status?.pageLabel, "Page 10")
        XCTAssertEqual(status?.updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testStatusIsUpToDateWhenLocalMatchesRemote() {
        let (store, _, _) = makeStore()
        let book = makeBook(title: "Synced", fileName: "synced.pdf")
        store.books = [book]

        store.savePDFPage(book: book, pageIndex: 2, updatedAt: Date(timeIntervalSince1970: 100))

        let status = store.cloudSyncStatuses().first
        XCTAssertEqual(status?.state, .upToDate)
        XCTAssertEqual(status?.pageLabel, "Page 3")
    }

    func testStatusesAreSortedMostRecentFirst() {
        let (store, _, _) = makeStore()
        let older = makeBook(title: "Older", fileName: "older.pdf")
        let newer = makeBook(title: "Newer", fileName: "newer.pdf")
        store.books = [older, newer]

        store.savePDFPage(book: older, pageIndex: 0, updatedAt: Date(timeIntervalSince1970: 100))
        store.savePDFPage(book: newer, pageIndex: 0, updatedAt: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.cloudSyncStatuses().map(\.book.title), ["Newer", "Older"])
    }

    func testEpochZeroBaselineReportsPendingUploadWithoutTimestamp() throws {
        let defaults = makeDefaults()
        let (store, cloud, _) = makeStore(defaults: defaults)
        let book = makeBook(title: "Pre-Sync", fileName: "pre-sync.pdf")
        store.books = [book]

        let baseline = CloudReadingProgress(book: book, pageIndex: 2, updatedAt: Date(timeIntervalSince1970: 0))
        defaults.set(try JSONEncoder().encode(baseline), forKey: "cloudProgress_\(book.id.uuidString)")

        let status = store.cloudSyncStatuses().first
        XCTAssertEqual(status?.state, .pendingUpload)
        XCTAssertNil(status?.updatedAt)
        XCTAssertEqual(status?.pageLabel, "Page 3")

        store.forceCloudSync()
        XCTAssertNil(cloud.progress(for: book), "a stale epoch-0 baseline must not be pushed to iCloud")
    }

    // MARK: - forceCloudSync

    func testForceSyncPushesNewerLocalProgress() {
        let (store, cloud, fake) = makeStore()
        let book = makeBook(title: "Push", fileName: "push.pdf")
        store.books = [book]

        store.savePDFPage(book: book, pageIndex: 3, updatedAt: Date(timeIntervalSince1970: 100))
        cloud.save(
            CloudReadingProgress(book: book, pageIndex: 0, updatedAt: Date(timeIntervalSince1970: 50)),
            for: book
        )

        let before = fake.synchronizeCount
        let date = store.forceCloudSync()

        XCTAssertEqual(cloud.progress(for: book)?.pageIndex, 3)
        XCTAssertEqual(cloud.progress(for: book)?.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertGreaterThan(fake.synchronizeCount, before)
        XCTAssertEqual(store.lastCloudSyncDate?.timeIntervalSince1970 ?? -1, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testForceSyncPullsNewerRemoteProgress() {
        let (store, cloud, _) = makeStore()
        let book = makeBook(title: "Pull", fileName: "pull.pdf")
        store.books = [book]

        store.savePDFPage(book: book, pageIndex: 1, updatedAt: Date(timeIntervalSince1970: 100))
        cloud.save(
            CloudReadingProgress(book: book, pageIndex: 7, updatedAt: Date(timeIntervalSince1970: 200)),
            for: book
        )
        XCTAssertEqual(store.getPDFPage(bookId: book.id), 1)

        store.forceCloudSync()

        XCTAssertEqual(store.getPDFPage(bookId: book.id), 7)
        XCTAssertEqual(store.cloudSyncStatuses().first?.state, .upToDate)
    }

    func testLastCloudSyncDateStartsNil() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.lastCloudSyncDate)
    }

    // MARK: - Helpers

    private func makeStore(
        defaults: UserDefaults? = nil
    ) -> (store: BookStore, cloud: CloudReadingProgressStore, fake: FakeCloudKeyValueStore) {
        let fake = FakeCloudKeyValueStore()
        let cloud = CloudReadingProgressStore(store: fake, notificationObject: fake)
        let store = BookStore(
            defaults: defaults ?? makeDefaults(),
            cloudProgressStore: cloud,
            notificationCenter: NotificationCenter()
        )
        return (store, cloud, fake)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CloudSyncStatusTests.\(UUID().uuidString)"
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
