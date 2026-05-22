import Foundation
import CloudKit

enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
    case disabled
}

@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published var syncStatus: SyncStatus = .disabled
    @Published var iCloudAvailable = false
    @Published var lastSyncDate: Date?

    weak var bookStore: BookStore?

    private let container = CKContainer(identifier: "iCloud.com.personal.EPUBReader")
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private let defaults = UserDefaults.standard

    private var positionPushTask: Task<Void, Never>?

    private static let recordTypeBook = "BookRecord"
    private static let recordTypePosition = "PositionRecord"
    private static let recordTypeHighlight = "HighlightRecord"

    private static let subscriptionSavedKey = "cloudkit_subscription_saved"

    // MARK: - iCloud Status

    func checkiCloudStatus() async {
        do {
            let status = try await container.accountStatus()
            iCloudAvailable = (status == .available)
            syncStatus = iCloudAvailable ? .idle : .disabled
        } catch {
            iCloudAvailable = false
            syncStatus = .disabled
        }
    }

    // MARK: - Full Sync

    func performFullSync() async {
        guard iCloudAvailable, let bookStore else { return }
        syncStatus = .syncing
        do {
            try await pullAllChanges(bookStore: bookStore)
            try await pushAllLocalData(bookStore: bookStore)
            lastSyncDate = Date()
            syncStatus = .idle
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Push Operations

    func pushBookMetadata(_ book: BookMetadata) async {
        guard iCloudAvailable else { return }
        let record = bookMetadataToRecord(book)
        do {
            try await saveRecord(record)
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    func pushReadingPosition(_ position: ReadingPosition, bookId: UUID) async {
        guard iCloudAvailable else { return }
        positionPushTask?.cancel()
        positionPushTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            let record = self.readingPositionToRecord(position, bookId: bookId)
            do {
                try await self.saveRecord(record)
            } catch {
                self.syncStatus = .error(error.localizedDescription)
            }
        }
    }

    func pushHighlight(_ highlight: BookHighlight, bookId: UUID) async {
        guard iCloudAvailable else { return }
        let record = highlightToRecord(highlight, bookId: bookId)
        do {
            try await saveRecord(record)
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    func deleteBook(_ bookId: UUID) async {
        guard iCloudAvailable else { return }
        do {
            let recordID = CKRecord.ID(recordName: bookId.uuidString)
            let record: CKRecord
            do {
                record = try await privateDB.record(for: recordID)
            } catch {
                record = CKRecord(recordType: Self.recordTypeBook, recordID: recordID)
            }
            record["isDeleted"] = 1 as CKRecordValue
            record["modifiedDate"] = Date() as CKRecordValue
            try await saveRecord(record)
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    func deleteHighlight(_ highlightId: UUID) async {
        guard iCloudAvailable else { return }
        do {
            let recordID = CKRecord.ID(recordName: highlightId.uuidString)
            let record: CKRecord
            do {
                record = try await privateDB.record(for: recordID)
            } catch {
                record = CKRecord(recordType: Self.recordTypeHighlight, recordID: recordID)
            }
            record["isDeleted"] = 1 as CKRecordValue
            try await saveRecord(record)
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Pull Operations

    private func pullAllChanges(bookStore: BookStore) async throws {
        let books = try await fetchAllRecords(ofType: Self.recordTypeBook)
        let positions = try await fetchAllRecords(ofType: Self.recordTypePosition)
        let highlights = try await fetchAllRecords(ofType: Self.recordTypeHighlight)

        mergeBooks(books, bookStore: bookStore)
        mergePositions(positions, bookStore: bookStore)
        mergeHighlights(highlights, bookStore: bookStore)
    }

    // MARK: - Subscription

    func setupSubscriptions() async {
        guard iCloudAvailable else { return }
        guard !defaults.bool(forKey: Self.subscriptionSavedKey) else { return }

        let subscription = CKDatabaseSubscription(subscriptionID: "all-changes")
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            try await privateDB.save(subscription)
            defaults.set(true, forKey: Self.subscriptionSavedKey)
        } catch {}
    }

    func handleRemoteNotification() async {
        guard iCloudAvailable, let bookStore else { return }
        do {
            try await pullAllChanges(bookStore: bookStore)
            lastSyncDate = Date()
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Record Conversions

    private func bookMetadataToRecord(_ book: BookMetadata) -> CKRecord {
        let recordID = CKRecord.ID(recordName: book.id.uuidString)
        let record = CKRecord(recordType: Self.recordTypeBook, recordID: recordID)
        record["bookId"] = book.id.uuidString as CKRecordValue
        record["title"] = book.title as CKRecordValue
        record["author"] = book.author as CKRecordValue
        record["fileName"] = book.fileName as CKRecordValue
        record["dateAdded"] = book.dateAdded as CKRecordValue
        record["modifiedDate"] = book.effectiveModifiedDate as CKRecordValue
        record["isDeleted"] = 0 as CKRecordValue
        return record
    }

    private func readingPositionToRecord(_ position: ReadingPosition, bookId: UUID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "pos_\(bookId.uuidString)")
        let record = CKRecord(recordType: Self.recordTypePosition, recordID: recordID)
        record["bookId"] = bookId.uuidString as CKRecordValue
        record["chapterIndex"] = position.chapterIndex as CKRecordValue
        record["paragraphIndex"] = position.paragraphIndex as CKRecordValue
        record["globalWordIndex"] = position.globalWordIndex as CKRecordValue
        record["modifiedDate"] = Date() as CKRecordValue
        return record
    }

    private func highlightToRecord(_ highlight: BookHighlight, bookId: UUID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: highlight.id.uuidString)
        let record = CKRecord(recordType: Self.recordTypeHighlight, recordID: recordID)
        record["highlightId"] = highlight.id.uuidString as CKRecordValue
        record["bookId"] = bookId.uuidString as CKRecordValue
        record["text"] = highlight.text as CKRecordValue
        record["chapterName"] = highlight.chapterName as CKRecordValue
        record["dateCreated"] = highlight.dateCreated as CKRecordValue
        record["resourceHref"] = (highlight.resourceHref ?? "") as CKRecordValue
        record["textBefore"] = (highlight.textBefore ?? "") as CKRecordValue
        record["textAfter"] = (highlight.textAfter ?? "") as CKRecordValue
        record["isDeleted"] = 0 as CKRecordValue
        return record
    }

    private func recordToBookMetadata(_ record: CKRecord) -> BookMetadata? {
        guard let bookIdStr = record["bookId"] as? String,
              let bookId = UUID(uuidString: bookIdStr),
              let title = record["title"] as? String,
              let author = record["author"] as? String,
              let fileName = record["fileName"] as? String,
              let dateAdded = record["dateAdded"] as? Date else {
            return nil
        }
        return BookMetadata(
            id: bookId,
            title: title,
            author: author,
            fileName: fileName,
            dateAdded: dateAdded,
            modifiedDate: record["modifiedDate"] as? Date,
            isLocalOnly: true
        )
    }

    private func recordToReadingPosition(_ record: CKRecord) -> (UUID, ReadingPosition)? {
        guard let bookIdStr = record["bookId"] as? String,
              let bookId = UUID(uuidString: bookIdStr),
              let chapterIndex = record["chapterIndex"] as? Int,
              let paragraphIndex = record["paragraphIndex"] as? Int,
              let globalWordIndex = record["globalWordIndex"] as? Int else {
            return nil
        }
        return (bookId, ReadingPosition(
            chapterIndex: chapterIndex,
            paragraphIndex: paragraphIndex,
            globalWordIndex: globalWordIndex
        ))
    }

    private func recordToHighlight(_ record: CKRecord) -> (UUID, BookHighlight)? {
        guard let highlightIdStr = record["highlightId"] as? String,
              let highlightId = UUID(uuidString: highlightIdStr),
              let bookIdStr = record["bookId"] as? String,
              let bookId = UUID(uuidString: bookIdStr),
              let text = record["text"] as? String,
              let chapterName = record["chapterName"] as? String,
              let dateCreated = record["dateCreated"] as? Date else {
            return nil
        }
        let resourceHref = record["resourceHref"] as? String
        let textBefore = record["textBefore"] as? String
        let textAfter = record["textAfter"] as? String
        return (bookId, BookHighlight(
            id: highlightId,
            text: text,
            chapterName: chapterName,
            dateCreated: dateCreated,
            resourceHref: resourceHref?.isEmpty == true ? nil : resourceHref,
            textBefore: textBefore?.isEmpty == true ? nil : textBefore,
            textAfter: textAfter?.isEmpty == true ? nil : textAfter
        ))
    }

    // MARK: - Merge Logic

    private func mergeBooks(_ records: [CKRecord], bookStore: BookStore) {
        var changed = false
        for record in records {
            let isDeleted = (record["isDeleted"] as? Int ?? 0) == 1
            guard let remote = recordToBookMetadata(record) else { continue }

            if let localIndex = bookStore.books.firstIndex(where: { $0.id == remote.id }) {
                if isDeleted {
                    bookStore.books.remove(at: localIndex)
                    changed = true
                } else {
                    let local = bookStore.books[localIndex]
                    if remote.effectiveModifiedDate > local.effectiveModifiedDate {
                        var updated = remote
                        updated.isLocalOnly = !local.hasLocalFile
                        bookStore.books[localIndex] = updated
                        changed = true
                    }
                }
            } else if !isDeleted {
                bookStore.books.insert(remote, at: 0)
                changed = true
            }
        }
        if changed {
            bookStore.persistBooks()
        }
    }

    private func mergePositions(_ records: [CKRecord], bookStore: BookStore) {
        for record in records {
            guard let (bookId, remotePos) = recordToReadingPosition(record) else { continue }
            let localPos = bookStore.getReadingPosition(bookId: bookId)
            if let local = localPos {
                if remotePos.globalWordIndex > local.globalWordIndex {
                    bookStore.saveReadingPosition(bookId: bookId, position: remotePos, syncToCloud: false)
                }
            } else {
                bookStore.saveReadingPosition(bookId: bookId, position: remotePos, syncToCloud: false)
            }
        }
    }

    private func mergeHighlights(_ records: [CKRecord], bookStore: BookStore) {
        var highlightsByBook: [UUID: [(BookHighlight, Bool)]] = [:]
        for record in records {
            let isDeleted = (record["isDeleted"] as? Int ?? 0) == 1
            guard let (bookId, highlight) = recordToHighlight(record) else { continue }
            highlightsByBook[bookId, default: []].append((highlight, isDeleted))
        }

        for (bookId, remoteHighlights) in highlightsByBook {
            var localHighlights = bookStore.getHighlights(bookId: bookId)
            var changed = false

            for (remoteHighlight, isDeleted) in remoteHighlights {
                let localIndex = localHighlights.firstIndex(where: { $0.id == remoteHighlight.id })

                if isDeleted {
                    if let idx = localIndex {
                        localHighlights.remove(at: idx)
                        changed = true
                    }
                } else if localIndex == nil {
                    localHighlights.append(remoteHighlight)
                    changed = true
                }
            }

            if changed {
                localHighlights.sort { $0.dateCreated < $1.dateCreated }
                bookStore.persistHighlights(localHighlights, bookId: bookId)
            }
        }
    }

    // MARK: - Push All Local Data

    private func pushAllLocalData(bookStore: BookStore) async throws {
        var records: [CKRecord] = []

        for book in bookStore.books {
            records.append(bookMetadataToRecord(book))

            if let position = bookStore.getReadingPosition(bookId: book.id) {
                records.append(readingPositionToRecord(position, bookId: book.id))
            }

            let highlights = bookStore.getHighlights(bookId: book.id)
            for highlight in highlights {
                records.append(highlightToRecord(highlight, bookId: book.id))
            }
        }

        try await batchSave(records)
    }

    // MARK: - CloudKit Helpers

    private nonisolated func saveRecord(_ record: CKRecord) async throws {
        let modifyOp = CKModifyRecordsOperation(recordsToSave: [record])
        modifyOp.savePolicy = .changedKeys
        modifyOp.qualityOfService = .userInitiated

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            modifyOp.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.privateDB.add(modifyOp)
        }
    }

    private nonisolated func batchSave(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }

        let batchSize = 400
        for startIndex in stride(from: 0, to: records.count, by: batchSize) {
            let endIndex = min(startIndex + batchSize, records.count)
            let batch = Array(records[startIndex..<endIndex])

            let modifyOp = CKModifyRecordsOperation(recordsToSave: batch)
            modifyOp.savePolicy = .changedKeys
            modifyOp.qualityOfService = .utility

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                modifyOp.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                self.privateDB.add(modifyOp)
            }
        }
    }

    private nonisolated func fetchAllRecords(ofType recordType: String) async throws -> [CKRecord] {
        var allRecords: [CKRecord] = []
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var cursor: CKQueryResultCursor?

        let (results, nextCursor) = try await privateDB.records(matching: query, resultsLimit: 200)
        for (_, result) in results {
            if let record = try? result.get() {
                allRecords.append(record)
            }
        }
        cursor = nextCursor

        while let activeCursor = cursor {
            let (moreResults, moreCursor) = try await privateDB.records(continuingMatchFrom: activeCursor, resultsLimit: 200)
            for (_, result) in moreResults {
                if let record = try? result.get() {
                    allRecords.append(record)
                }
            }
            cursor = moreCursor
        }

        return allRecords
    }
}
