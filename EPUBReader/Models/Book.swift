import Foundation
import SwiftUI

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
    let resourceHref: String
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

// MARK: - Reader Theme

enum ReaderTheme: String, CaseIterable {
    case system, light, dark, sepia

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        case .sepia: return "Sepia"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .system: return Color(.systemBackground)
        case .light: return .white
        case .dark: return Color(red: 0.11, green: 0.11, blue: 0.13)
        case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.87)
        }
    }

    var textColor: Color {
        switch self {
        case .system: return Color(.label)
        case .light: return Color(white: 0.12)
        case .dark: return Color(white: 0.85)
        case .sepia: return Color(red: 0.36, green: 0.26, blue: 0.18)
        }
    }

    var secondaryTextColor: Color {
        switch self {
        case .system: return Color(.secondaryLabel)
        case .light: return Color(white: 0.4)
        case .dark: return Color(white: 0.55)
        case .sepia: return Color(red: 0.55, green: 0.45, blue: 0.35)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .sepia: return .light
        case .dark: return .dark
        }
    }
}
