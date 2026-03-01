import Foundation

struct BookMetadata: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var author: String
    let fileName: String
    var dateAdded: Date

    var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Books").appendingPathComponent(fileName)
    }
}

struct ReadingPosition: Codable {
    var chapterIndex: Int
    var paragraphIndex: Int
    var globalWordIndex: Int
}

struct ParsedBook {
    let metadata: BookMetadata
    let chapters: [BookChapter]
    let flatParagraphs: [BookParagraph]
    let totalWords: Int
}

struct BookChapter {
    let index: Int
    let title: String
    let paragraphs: [BookParagraph]
}

struct BookParagraph: Identifiable {
    let id: Int
    let text: String
    let words: [BookWord]
    let chapterIndex: Int
    let isHeading: Bool
}

struct BookWord: Identifiable {
    let id: Int
    let text: String
    let paragraphId: Int
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
