import Foundation

/// Builds throwaway exploded-EPUB directories in tmp so tests don't need committed binary fixtures.
enum EPUBFixtures {
    /// Minimal valid EPUB 3 as a directory: mimetype + container.xml + OPF + one chapter.
    static func explodedEPUB(named name: String = "Fixture.epub") throws -> URL {
        let dir = try uniqueRoot().appendingPathComponent(name, isDirectory: true)
        try write("application/epub+zip", to: dir, at: "mimetype")
        try write(containerXML, to: dir, at: "META-INF/container.xml")
        try write(packageOPF, to: dir, at: "OEBPS/package.opf")
        try write(chapterXHTML, to: dir, at: "OEBPS/chapter1.xhtml")
        return dir
    }

    static func nonEPUBDirectory() throws -> URL {
        let dir = try uniqueRoot().appendingPathComponent("NotABook", isDirectory: true)
        try write("just some text", to: dir, at: "notes.txt")
        return dir
    }

    /// Passes structural validation (container.xml present) but fails real
    /// parsing: the container declares no rootfile, which Readium rejects.
    static func unparseableEPUB(named name: String = "Broken.epub") throws -> URL {
        let dir = try uniqueRoot().appendingPathComponent(name, isDirectory: true)
        try write("application/epub+zip", to: dir, at: "mimetype")
        try write(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles/>
            </container>
            """,
            to: dir,
            at: "META-INF/container.xml"
        )
        return dir
    }

    /// Arbitrary directory with the given relative-path → content files.
    static func directory(named name: String = "Dir", files: [String: String]) throws -> URL {
        let dir = try uniqueRoot().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, content) in files {
            try write(content, to: dir, at: path)
        }
        return dir
    }

    /// Removes the unique root that contains the fixture.
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func uniqueRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func write(_ content: String, to dir: URL, at relativePath: String) throws {
        let fileURL = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static let packageOPF = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">urn:uuid:6c1f56e4-9d10-4a39-9e3b-1f9e2f3a0b11</dc:identifier>
        <dc:title>Test Book</dc:title>
        <dc:creator>Test Author</dc:creator>
        <dc:language>en</dc:language>
        <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
      </metadata>
      <manifest>
        <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="chapter1"/>
      </spine>
    </package>
    """

    private static let chapterXHTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>Chapter 1</title></head>
      <body><p>Hello world from the test book.</p></body>
    </html>
    """
}
