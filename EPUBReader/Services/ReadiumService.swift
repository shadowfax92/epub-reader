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

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL) {
        case .success(let a): asset = a
        case .failure(let error): throw ReadiumServiceError.openFailed(String(describing: error))
        }

        let publication: Publication
        switch await publicationOpener.open(asset: asset, allowUserInteraction: false) {
        case .success(let p): publication = p
        case .failure(let error): throw ReadiumServiceError.openFailed(String(describing: error))
        }

        return publication
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
