import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var bookStore: BookStore
    @State private var showFilePicker = false
    @State private var showSettings = false
    /// One entry per failed import batch; the alert drains it front-first so
    /// a batch landing while the alert is up is never lost.
    @State private var errorQueue: [String] = []
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if bookStore.books.isEmpty {
                emptyState
            } else {
                bookList
            }
        }
        .onDrop(of: BookDropImport.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            importDroppedItems(providers)
        }
        .overlay {
            if isDropTargeted {
                dropTargetOverlay
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
            allowedContentTypes: EPUBImport.allowedContentTypes + [.pdf],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(bookStore)
            }
        }
        .alert("Import Error", isPresented: errorAlertPresented) {
            Button("OK") { }
        } message: {
            Text(errorQueue.first ?? "Unknown error")
        }
    }

    /// Presented while the queue is non-empty; dismissal pops the front entry
    /// and SwiftUI re-presents for the next one.
    private var errorAlertPresented: Binding<Bool> {
        Binding(
            get: { !errorQueue.isEmpty },
            set: { presented in
                if !presented, !errorQueue.isEmpty {
                    errorQueue.removeFirst()
                }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "book.closed")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Books")
                .font(.title2)
                .fontWeight(.medium)
            Text("Import an EPUB or PDF from Files")
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
        // Fill the window so the drop target isn't just the content cluster
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            switch book.format {
            case .epub:
                ReaderView(book: book)
                    .environmentObject(bookStore)
            case .pdf:
                PDFReaderView(book: book)
                    .environmentObject(bookStore)
            }
        }
    }

    private var dropTargetOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8]))
                .padding(8)
            Label("Drop books to import", systemImage: "arrow.down.doc")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                var failures: [String] = []
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        _ = try await bookStore.importBook(from: url)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                presentFailures(failures)
            }

        case .failure(let error):
            errorQueue.append(error.localizedDescription)
        }
    }

    private func importDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var failures: [String] = []

            // Resolve every provider before any import: drop-session providers
            // go stale shortly after the drop, and importBook can block for
            // minutes on an iCloud download.
            var resolved: [BookDropImport.ResolvedItem] = []
            for provider in providers {
                do {
                    resolved.append(try await BookDropImport.resolveItem(from: provider))
                } catch {
                    // DropError messages already name the item
                    failures.append(error.localizedDescription)
                }
            }

            for item in resolved {
                defer {
                    if item.needsSecurityScopeRelease {
                        item.url.stopAccessingSecurityScopedResource()
                    }
                    if let tmp = item.ownedTemporaryDirectory {
                        // Detached: deleting an exploded-EPUB tree shouldn't
                        // hitch the main actor.
                        Task.detached(priority: .utility) {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                    }
                }
                do {
                    _ = try await bookStore.importBook(from: item.url)
                } catch {
                    failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            presentFailures(failures)
        }
        return true
    }

    private func presentFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        errorQueue.append(failures.joined(separator: "\n"))
    }
}
