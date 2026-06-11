import Foundation
import ReadiumShared
import ReadiumStreamer
import ReadiumAdapterGCDWebServer
import ReadiumNavigator

@MainActor
final class ReadiumService {
    static let shared = ReadiumService()

    private nonisolated(unsafe) let httpClient: HTTPClient
    nonisolated(unsafe) let assetRetriever: AssetRetriever
    let httpServer: HTTPServer
    nonisolated(unsafe) let publicationOpener: PublicationOpener

    private init() {
        httpClient = DefaultHTTPClient()
        assetRetriever = AssetRetriever(httpClient: httpClient)
        httpServer = GCDHTTPServer(assetRetriever: assetRetriever)
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    func openPublication(at url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else {
            throw ReadiumServiceError.invalidURL
        }

        let asset = try await retrieveAsset(for: fileURL)

        let publication: Publication
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case .success(let p): publication = p
        case .failure(let error): throw ReadiumServiceError.openFailed(String(describing: error))
        }

        return publication
    }

    /// Resolves a file or exploded-EPUB directory into a Readium asset.
    /// AssetRetriever only handles regular files; directories must be wrapped
    /// in a DirectoryContainer ourselves, with an EPUB hint because the
    /// hint-less sniffer requires a `mimetype` entry that some exploded
    /// EPUBs lack.
    private nonisolated func retrieveAsset(for fileURL: FileURL) async throws -> Asset {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            // Re-derive the URL with a directory hint: callers often build it
            // via appendingPathComponent (no trailing slash), and resolving a
            // relative entry like "mimetype" against a slash-less base drops
            // the last path segment.
            guard let directoryURL = FileURL(path: fileURL.path, isDirectory: true) else {
                throw ReadiumServiceError.invalidURL
            }
            let container: DirectoryContainer
            do {
                container = try await DirectoryContainer(directory: directoryURL)
            } catch {
                throw ReadiumServiceError.openFailed(String(describing: error))
            }
            switch await assetRetriever.retrieve(container: container, hints: FormatHints(mediaType: .epub)) {
            case .success(let asset): return asset
            case .failure(let error): throw ReadiumServiceError.openFailed(String(describing: error))
            }
        }

        switch await assetRetriever.retrieve(url: fileURL) {
        case .success(let asset): return asset
        case .failure(let error): throw ReadiumServiceError.openFailed(String(describing: error))
        }
    }

    func makeNavigator(
        publication: Publication,
        initialLocation: Locator?,
        preferences: EPUBPreferences = .empty,
        editingActions: [EditingAction] = EditingAction.defaultActions
    ) throws -> EPUBNavigatorViewController {
        try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: EPUBNavigatorViewController.Configuration(
                preferences: preferences,
                editingActions: editingActions
            ),
            httpServer: httpServer
        )
    }
}

enum ReadiumServiceError: LocalizedError {
    case invalidURL
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid book file URL."
        case .openFailed(let msg): return "Failed to open book: \(msg)"
        }
    }
}
