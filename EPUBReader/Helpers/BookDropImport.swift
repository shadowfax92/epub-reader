import Foundation
import UniformTypeIdentifiers

/// Resolves drag-and-dropped item providers into local, readable URLs for
/// `BookStore.importBook`. Prefers the in-place file URL that Finder and
/// Files drops carry; falls back to asking the provider to materialize a
/// copy when the URL is absent or unreadable from the sandbox.
@MainActor
enum BookDropImport {
    /// Types the library drop zone accepts. `.fileURL` is what Finder drags
    /// register; the content types cover providers that only offer data.
    nonisolated static let acceptedTypes: [UTType] = [.fileURL, .epub, .pdf, .folder, .package]

    /// Content types worth materializing a copy for, in preference order.
    nonisolated private static let copyableTypes: [UTType] = [.epub, .pdf, .folder, .package]

    struct ResolvedItem {
        let url: URL
        /// True when `url` is under `startAccessingSecurityScopedResource`
        /// and the caller must balance it with a stop after importing.
        let needsSecurityScopeRelease: Bool
        /// Directory we own holding a materialized copy; the caller deletes
        /// it after importing. Nil when the item is used in place.
        let ownedTemporaryDirectory: URL?
    }

    enum DropError: LocalizedError {
        case noImportableContent(String)
        case copyFailed(String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .noImportableContent(let name):
                return "\(name) isn't an EPUB, PDF, or folder."
            case .copyFailed(let name, let underlying):
                return "Couldn't copy \(name): \(underlying.localizedDescription)"
            }
        }
    }

    static func resolveItem(from provider: NSItemProvider) async throws -> ResolvedItem {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = try? await loadFileURL(from: provider) {
            let scoped = url.startAccessingSecurityScopedResource()
            if FileManager.default.isReadableFile(atPath: url.path) {
                return ResolvedItem(
                    url: url,
                    needsSecurityScopeRelease: scoped,
                    ownedTemporaryDirectory: nil
                )
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return try await copyRepresentation(from: provider)
    }

    /// First registered identifier conforming to a copyable book type, so the
    /// provider's own ordering (most specific first) picks the representation.
    nonisolated static func copyableTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return copyableTypes.contains { type.conforms(to: $0) }
        }
    }

    private static func loadFileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                }
            }
        }
    }

    private static func copyRepresentation(from provider: NSItemProvider) async throws -> ResolvedItem {
        let name = provider.suggestedName ?? "Dropped item"
        guard let typeIdentifier = copyableTypeIdentifier(for: provider) else {
            throw DropError.noImportableContent(name)
        }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        do {
            let url = try await loadCopy(from: provider, typeIdentifier: typeIdentifier, into: stagingDir)
            return ResolvedItem(url: url, needsSecurityScopeRelease: false, ownedTemporaryDirectory: stagingDir)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            throw DropError.copyFailed(name, underlying: error)
        }
    }

    private static func loadCopy(
        from provider: NSItemProvider,
        typeIdentifier: String,
        into directory: URL
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // The system deletes its copy when this handler returns, so
                // the file must be claimed synchronously here.
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
