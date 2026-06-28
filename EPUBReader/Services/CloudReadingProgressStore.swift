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
        var candidates: [CloudReadingProgress] = []
        for key in CloudReadingProgress.storageKeys(for: book) {
            guard let progress = progress(forStorageKey: key),
                  CloudReadingProgress.matches(progress, book: book) else { continue }
            candidates.append(progress.bookKey == CloudReadingProgress.bookKey(for: book) ? progress : progress.migrated(to: book))
        }
        return candidates.max { $0.updatedAt < $1.updatedAt }
    }

    func save(_ progress: CloudReadingProgress, for book: BookMetadata) {
        guard progress.bookKey == CloudReadingProgress.bookKey(for: book),
              let data = try? JSONEncoder().encode(progress),
              let value = String(data: data, encoding: .utf8) else { return }
        store.set(value, forKey: CloudReadingProgress.storageKey(for: book))
        store.synchronize()
    }

    func removeProgress(for book: BookMetadata) {
        store.removeObject(forKey: CloudReadingProgress.storageKey(for: book))
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
}
