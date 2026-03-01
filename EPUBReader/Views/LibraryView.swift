import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var bookStore: BookStore
    @State private var showFilePicker = false
    @State private var showSettings = false
    @State private var importError: String?
    @State private var showError = false

    var body: some View {
        Group {
            if bookStore.books.isEmpty {
                emptyState
            } else {
                bookList
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button { showFilePicker = true } label: {
                        Image(systemName: "plus")
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? UTType("org.idpf.epub-container") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(bookStore)
            }
        }
        .alert("Import Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(importError ?? "Unknown error")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Books")
                .font(.title2)
                .fontWeight(.medium)
            Text("Import an EPUB from Files")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showFilePicker = true
            } label: {
                Label("Import Book", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.tint)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
    }

    private var bookList: some View {
        List {
            ForEach(bookStore.books) { book in
                NavigationLink(value: book) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(book.author)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    bookStore.removeBook(bookStore.books[index])
                }
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: BookMetadata.self) { book in
            ReaderView(book: book)
                .environmentObject(bookStore)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()

            Task {
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let _ = try await bookStore.importBook(from: url)
                } catch {
                    importError = error.localizedDescription
                    showError = true
                }
            }

        case .failure(let error):
            importError = error.localizedDescription
            showError = true
        }
    }
}
