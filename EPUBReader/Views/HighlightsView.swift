import SwiftUI

struct HighlightsView: View {
    let book: BookMetadata
    @EnvironmentObject var bookStore: BookStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareText: String?

    private var highlights: [BookHighlight] {
        bookStore.getHighlights(bookId: book.id)
    }

    var body: some View {
        Group {
            if highlights.isEmpty {
                ContentUnavailableView(
                    "No Highlights",
                    systemImage: "highlighter",
                    description: Text("Select text in the book and tap Highlight to save passages.")
                )
            } else {
                List {
                    ForEach(highlights) { highlight in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(highlight.chapterName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(highlight.text)
                                .font(.body)
                            Text(highlight.dateCreated, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            bookStore.removeHighlight(id: highlights[index].id, bookId: book.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Highlights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            if !highlights.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: bookStore.exportHighlightsMarkdown(bookTitle: book.title, bookId: book.id),
                        subject: Text("Highlights from \(book.title)"),
                        message: Text("Highlights from \(book.title)")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
