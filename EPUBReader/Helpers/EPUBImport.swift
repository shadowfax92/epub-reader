import Foundation
import UniformTypeIdentifiers

/// Rules for what the book-import picker accepts and what counts as an
/// importable exploded-EPUB folder. `.folder` is required because exploded
/// EPUBs (directories named `*.epub`) don't conform to the epub file type,
/// so the picker would grey them out.
enum EPUBImport {
    static let allowedContentTypes: [UTType] = [.epub, .folder]

    /// True when `url` is a directory shaped like an exploded EPUB:
    /// `META-INF/container.xml` present, or a `mimetype` file declaring
    /// `application/epub+zip` (OCF spec; matches Readium's sniffer).
    static func isExplodedEPUBDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }

        let containerXML = url.appendingPathComponent("META-INF/container.xml")
        if FileManager.default.fileExists(atPath: containerXML.path) {
            return true
        }

        let mimetype = url.appendingPathComponent("mimetype")
        guard let contents = try? String(contentsOf: mimetype, encoding: .utf8) else {
            return false
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
    }
}
