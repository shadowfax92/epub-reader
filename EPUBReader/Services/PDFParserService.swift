import Foundation
import PDFKit

struct PDFMetadataResult {
    let title: String?
    let author: String?
}

/// PDF counterpart of EPUBParserService: extracts import metadata via PDFKit.
@MainActor
final class PDFParserService {
    static let shared = PDFParserService()

    func parseMetadata(from url: URL) -> PDFMetadataResult {
        guard let document = PDFDocument(url: url) else {
            return PDFMetadataResult(title: nil, author: nil)
        }
        let attributes = document.documentAttributes ?? [:]
        return PDFMetadataResult(
            title: nonEmptyAttribute(attributes[PDFDocumentAttribute.titleAttribute]),
            author: nonEmptyAttribute(attributes[PDFDocumentAttribute.authorAttribute])
        )
    }

    private func nonEmptyAttribute(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }
}
