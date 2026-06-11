import SwiftUI
import PDFKit

/// Moves a non-Sendable value across an isolation boundary the compiler can't prove safe;
/// caller guarantees no concurrent access until the receiving side finishes.
private struct UnsafeTransfer<T>: @unchecked Sendable {
    let value: T
}

/// PDF counterpart of ReaderView: renders the original pages via PDFKit and drives the
/// same AudioPlaybackManager, translating the spoken global word index into an on-page
/// highlight through the parser's geometry side-table.
struct PDFReaderView: View {
    let book: BookMetadata
    @EnvironmentObject var bookStore: BookStore
    @StateObject private var playbackManager = AudioPlaybackManager()
    @Environment(\.dismiss) private var dismiss

    @State private var pdfDocument: PDFDocument?
    @State private var parsedPDF: ParsedPDFBook?
    @State private var proxy = PDFViewProxy()
    @State private var showControls = true
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var currentSpeed: Double = 1.0
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var showPageList = false
    @State private var showSettings = false
    @State private var hasTextSelection = false
    @State private var currentHighlight: PDFWordHighlight?
    @State private var initialPageIndex: Int?

    private var theme: ReaderTheme { bookStore.readerTheme }

    private var bookProgressPercent: Int? {
        guard let total = parsedPDF?.book.totalWords, total > 0 else { return nil }
        let current = playbackManager.currentGlobalWordIndex
        return min(100, max(0, current * 100 / total))
    }

    var body: some View {
        ZStack {
            theme.backgroundColor
                .ignoresSafeArea()

            if let pdfDocument {
                PDFKitReaderView(
                    document: pdfDocument,
                    proxy: proxy,
                    highlight: currentHighlight,
                    backgroundColor: UIColor(theme.backgroundColor),
                    initialPageIndex: initialPageIndex,
                    onTap: { toggleControls() },
                    onSelectionChanged: { hasTextSelection = $0 },
                    onVisiblePageChanged: { pageIndex in
                        bookStore.savePDFPage(bookId: book.id, pageIndex: pageIndex)
                    }
                )
                .ignoresSafeArea()
            } else if isLoading {
                ProgressView("Loading book...")
            } else if let loadError {
                errorView(loadError)
            }

            if showControls, pdfDocument != nil {
                controlsOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showControls)
        .preferredColorScheme(theme.colorScheme)
        .task { await loadBook() }
        .onDisappear {
            playbackManager.stop()
        }
        .onChange(of: playbackManager.isPlaying) { _, playing in
            if playing { scheduleHideControls() }
        }
        .onChange(of: playbackManager.currentGlobalWordIndex) { _, _ in
            updateWordHighlight()
        }
        .sheet(isPresented: $showPageList) {
            pageListSheet
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(bookStore)
            }
        }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { reconfigurePlayback() }
        }
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                }

                Spacer()

                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 4) {
                    Button { showPageList = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 44)
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 44)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .background(.ultraThinMaterial)

            Spacer()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = false
                    }
                }

            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)

                PlaybackControlsView(
                    playbackManager: playbackManager,
                    currentSpeed: $currentSpeed,
                    progressPercent: bookProgressPercent,
                    onSpeedChange: { bookStore.playbackSpeed = $0 },
                    onPlayPause: handlePlayPause
                ) {
                    if parsedPDF?.book.totalWords == 0 {
                        Text("No readable text in this PDF — listening is unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } actionAccessory: {
                    selectionActionsRow
                }

                Spacer().frame(height: 8)
            }
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
        }
        .transition(.opacity)
    }

    private var selectionActionsRow: some View {
        HStack(spacing: 12) {
            if hasTextSelection {
                Button {
                    playFromSelection()
                } label: {
                    Label("Play from selection", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }

            Button {
                jumpToCurrentPosition()
            } label: {
                Label("Jump to position", systemImage: "scope")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(.systemGray5)))
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Page List

    private var pageListSheet: some View {
        NavigationStack {
            List {
                if let chapters = parsedPDF?.book.chapters {
                    ForEach(chapters, id: \.index) { chapter in
                        Button {
                            navigateToChapter(chapter)
                            showPageList = false
                        } label: {
                            HStack {
                                Text(chapter.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if chapter.index == currentChapterIndex {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPageList = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentChapterIndex: Int {
        guard let parsedPDF else { return -1 }
        let currentParaId = playbackManager.currentParagraphId
        return parsedPDF.book.flatParagraphs.first(where: { $0.id == currentParaId })?.chapterIndex ?? -1
    }

    // MARK: - Actions

    private func loadBook() async {
        guard let document = PDFDocument(url: book.fileURL) else {
            loadError = "Could not open this PDF file."
            isLoading = false
            return
        }

        if document.isLocked {
            loadError = "This PDF is password-protected and can't be opened."
            isLoading = false
            return
        }

        // Parse off the main actor — page.string over a long document blocks for seconds.
        // The view doesn't touch the document until the await returns, so the transfer is safe.
        let boxedDocument = UnsafeTransfer(value: document)
        let metadata = book
        let parsed = await Task.detached(priority: .userInitiated) {
            PDFParserService.shared.parseBook(from: metadata, document: boxedDocument.value)
        }.value
        parsedPDF = parsed

        playbackManager.setBook(paragraphs: parsed.book.flatParagraphs)
        currentSpeed = bookStore.playbackSpeed
        reconfigurePlayback()

        if let position = bookStore.getReadingPosition(bookId: book.id) {
            let paraIdx = min(position.paragraphIndex, parsed.book.flatParagraphs.count - 1)
            if paraIdx >= 0 {
                playbackManager.restorePosition(
                    paragraphArrayIndex: paraIdx,
                    paragraphId: parsed.book.flatParagraphs[paraIdx].id,
                    globalWordIndex: position.globalWordIndex
                )
            }
        }

        initialPageIndex = bookStore.getPDFPage(bookId: book.id)
            ?? parsed.wordLocations[safe: playbackManager.currentGlobalWordIndex]?.pageIndex

        pdfDocument = document
        isLoading = false
    }

    private func reconfigurePlayback() {
        currentSpeed = bookStore.playbackSpeed
        playbackManager.configure(
            provider: bookStore.ttsProvider,
            apiKey: bookStore.activeApiKey,
            voiceId: bookStore.activeVoiceId,
            speed: currentSpeed,
            onPositionUpdate: { position in
                bookStore.saveReadingPosition(bookId: book.id, position: position)
            }
        )
    }

    private func handlePlayPause() {
        if playbackManager.isPlaying {
            playbackManager.pause()
            return
        }

        guard let parsedPDF, parsedPDF.book.totalWords > 0 else {
            playbackManager.error = "No readable text in this PDF (scanned images?)."
            return
        }

        if bookStore.activeApiKey.isEmpty || bookStore.activeVoiceId.isEmpty {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        reconfigurePlayback()

        if hasTextSelection, let start = selectionStartPosition() {
            playbackManager.play(fromParagraphIndex: start.paragraphIndex, wordIndex: start.wordIndex)
            proxy.clearSelection()
            hasTextSelection = false
            return
        }

        let position = bookStore.getReadingPosition(bookId: book.id)
        let paragraphIdx = position?.paragraphIndex ?? 0
        let wordIdx = position?.globalWordIndex ?? 0
        playbackManager.play(fromParagraphIndex: paragraphIdx, wordIndex: wordIdx)
    }

    private func playFromSelection() {
        guard !bookStore.activeApiKey.isEmpty, !bookStore.activeVoiceId.isEmpty else {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        guard let start = selectionStartPosition() else { return }

        reconfigurePlayback()
        playbackManager.play(fromParagraphIndex: start.paragraphIndex, wordIndex: start.wordIndex)
        proxy.clearSelection()
        hasTextSelection = false
    }

    private func selectionStartPosition() -> (paragraphIndex: Int, wordIndex: Int)? {
        guard let parsedPDF,
              let pdfDocument,
              let info = proxy.currentSelectionInfo(),
              let page = pdfDocument.page(at: info.pageIndex),
              let pageString = page.string else { return nil }

        return PDFSelectionMapper.findStartPosition(
            selectionText: info.text,
            selectionStartOffset: info.startOffset,
            pageIndex: info.pageIndex,
            pageString: pageString,
            paragraphs: parsedPDF.book.flatParagraphs,
            wordLocations: parsedPDF.wordLocations
        )
    }

    private func navigateToChapter(_ chapter: BookChapter) {
        guard let parsedPDF,
              let pageIndex = parsedPDF.chapterPageIndices[safe: chapter.index] else { return }

        proxy.goToPage(pageIndex)

        if let firstParagraph = chapter.paragraphs.first,
           let index = parsedPDF.book.flatParagraphs.firstIndex(where: { $0.id == firstParagraph.id }),
           !bookStore.activeApiKey.isEmpty, !bookStore.activeVoiceId.isEmpty {
            reconfigurePlayback()
            playbackManager.play(fromParagraphIndex: index, wordIndex: firstParagraph.words.first?.id ?? 0)
        }
    }

    // MARK: - Word Highlight

    private func updateWordHighlight() {
        guard let parsedPDF,
              let location = parsedPDF.wordLocations[safe: playbackManager.currentGlobalWordIndex] else {
            currentHighlight = nil
            return
        }
        currentHighlight = PDFWordHighlight(pageIndex: location.pageIndex, range: location.range)
    }

    private func jumpToCurrentPosition() {
        guard let parsedPDF,
              let location = parsedPDF.wordLocations[safe: playbackManager.currentGlobalWordIndex] else { return }
        proxy.scrollTo(pageIndex: location.pageIndex, range: location.range)
    }

    // MARK: - Helpers

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if playbackManager.isPlaying && showControls {
            scheduleHideControls()
        }
    }

    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, playbackManager.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Failed to load book")
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Go Back") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
