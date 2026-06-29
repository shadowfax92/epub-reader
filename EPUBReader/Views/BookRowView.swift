import SwiftUI

/// A single Library row: title + author, plus a small whole-book reading-progress
/// indicator (thin bar + `NN%`) shown once the book has been opened.
///
/// The fraction is computed asynchronously so a one-off PDF page-count load never blocks
/// the list, and is refreshed whenever the row reappears (e.g. on return from the reader).
struct BookRowView: View {
    let book: BookMetadata
    @EnvironmentObject var bookStore: BookStore
    @State private var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title)
                .font(.headline)
                .lineLimit(2)
            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let fraction, let percent = ReadingProgress.percent(fraction) {
                progressIndicator(fraction: fraction, percent: percent)
            }
        }
        .padding(.vertical, 4)
        .onAppear { refreshProgress() }
    }

    private func progressIndicator(fraction: Double, percent: Int) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 140)
            Text("\(percent)%")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private func refreshProgress() {
        Task { fraction = await bookStore.progressFraction(for: book) }
    }
}
