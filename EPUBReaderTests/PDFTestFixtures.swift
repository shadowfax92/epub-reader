import UIKit
import PDFKit

/// Generates throwaway PDF files with real extractable text (drawn via Core Text),
/// so parser tests don't need binary fixtures in the repo.
enum PDFTestFixtures {

    /// Each element of `pages` is drawn on its own page; an empty string yields a page with no text.
    static func makePDF(pages: [String], title: String? = nil, author: String? = nil, password: String? = nil) throws -> URL {
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [:]
        if let title { info[kCGPDFContextTitle as String] = title }
        if let author { info[kCGPDFContextAuthor as String] = author }
        if let password {
            info[kCGPDFContextUserPassword as String] = password
            info[kCGPDFContextOwnerPassword as String] = password
        }
        format.documentInfo = info

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let data = renderer.pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                guard !text.isEmpty else { continue }
                (text as NSString).draw(
                    in: pageRect.insetBy(dx: 36, dy: 36),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
                )
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: url)
        return url
    }
}
