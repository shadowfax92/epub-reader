import Foundation

protocol CloudReadingProgressKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudReadingProgressKeyValueStore {}

final class CloudReadingProgressStore {
    private let store: CloudReadingProgressKeyValueStore
    let notificationObject: AnyObject?

    init(
        store: CloudReadingProgressKeyValueStore = NSUbiquitousKeyValueStore.default,
        notificationObject: AnyObject? = NSUbiquitousKeyValueStore.default
    ) {
        self.store = store
        self.notificationObject = notificationObject
    }

    /// Reads the iCloud progress record for the book, tolerating missing or corrupt values.
    func progress(for book: BookMetadata) -> CloudReadingProgress? {
        if let progress = progress(forStorageKey: CloudReadingProgress.storageKey(for: book)),
           progress.bookKey == CloudReadingProgress.bookKey(for: book) {
            return progress
        }

        guard let progress = progress(forStorageKey: CloudReadingProgress.metadataStorageKey(for: book)),
              progress.format == book.format else { return nil }
        return progress.migrated(to: book)
    }

    func save(_ progress: CloudReadingProgress, for book: BookMetadata) {
        guard progress.bookKey == CloudReadingProgress.bookKey(for: book),
              let data = try? JSONEncoder().encode(progress),
              let value = String(data: data, encoding: .utf8) else { return }
        store.set(value, forKey: CloudReadingProgress.storageKey(for: book))
        store.set(value, forKey: CloudReadingProgress.metadataStorageKey(for: book))
        store.synchronize()
    }

    /// Moves an existing synced record when a legacy book gains a stronger stable identity.
    func migrateProgress(from oldBook: BookMetadata, to newBook: BookMetadata) {
        let oldStorageKey = CloudReadingProgress.storageKey(for: oldBook)
        let newStorageKey = CloudReadingProgress.storageKey(for: newBook)
        guard oldStorageKey != newStorageKey,
              let oldProgress = progress(for: oldBook) else { return }

        let migrated = oldProgress.migrated(to: newBook)
        if let existing = progress(for: newBook),
           existing.isNewer(than: migrated) {
            removeMigratedSourceKey(oldStorageKey, newBook: newBook)
            store.synchronize()
            return
        }

        save(migrated, for: newBook)
        removeMigratedSourceKey(oldStorageKey, newBook: newBook)
        store.synchronize()
    }

    func removeProgress(for book: BookMetadata) {
        store.removeObject(forKey: CloudReadingProgress.storageKey(for: book))
        store.removeObject(forKey: CloudReadingProgress.metadataStorageKey(for: book))
        store.synchronize()
    }

    @discardableResult
    func synchronize() -> Bool {
        store.synchronize()
    }

    private func progress(forStorageKey key: String) -> CloudReadingProgress? {
        guard let value = store.string(forKey: key),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CloudReadingProgress.self, from: data)
    }

    private func removeMigratedSourceKey(_ oldStorageKey: String, newBook: BookMetadata) {
        guard oldStorageKey != CloudReadingProgress.storageKey(for: newBook),
              oldStorageKey != CloudReadingProgress.metadataStorageKey(for: newBook) else { return }
        store.removeObject(forKey: oldStorageKey)
    }
}
