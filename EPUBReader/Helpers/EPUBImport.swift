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
    /// Tolerates undownloaded iCloud entries (`.name.icloud` placeholders) so
    /// evicted-but-valid books aren't rejected before the coordinated copy.
    static func isExplodedEPUBDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return false
        }

        if entryExists(in: url, at: "META-INF/container.xml") {
            return true
        }

        let mimetype = url.appendingPathComponent("mimetype")
        if let contents = try? String(contentsOf: mimetype, encoding: .utf8) {
            return contents.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
        }
        // Placeholder-only mimetype: content unreadable until download, but a
        // folder carrying an OCF `mimetype` entry is an EPUB for our purposes;
        // Readium remains the final arbiter after the copy. A present-but-
        // undecodable real file is NOT treated as a declaration.
        return !FileManager.default.fileExists(atPath: mimetype.path)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent(".mimetype.icloud").path)
    }

    private static func entryExists(in dir: URL, at relativePath: String) -> Bool {
        let real = dir.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: real.path) {
            return true
        }
        let placeholder = real.deletingLastPathComponent()
            .appendingPathComponent(".\(real.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }
}
