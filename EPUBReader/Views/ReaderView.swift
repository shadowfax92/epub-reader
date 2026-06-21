import SwiftUI
import ReadiumShared
import ReadiumNavigator

private let selectionStartErrorMessage = "Could not start from that selection. Try selecting a little more text."

struct ReaderView: View {
    let book: BookMetadata
    @EnvironmentObject var bookStore: BookStore
    @StateObject private var playbackManager = AudioPlaybackManager()
    @Environment(\.dismiss) private var dismiss

    @State private var parsedBook: ParsedBook?
    @State private var publication: Publication?
    @State private var navigator: EPUBNavigatorViewController?
    @State private var showControls = true
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var currentSpeed: Double = 1.0
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var showChapterList = false
    @State private var showSettings = false
    @State private var showHighlights = false
    @State private var navigatorDelegate: ReaderNavigatorDelegate?
    @State private var lastScrolledResourceHref: String?
    @State private var hasTextSelection = false
    @State private var navigationTask: Task<Void, Never>?

    private var theme: ReaderTheme { bookStore.readerTheme }

    private var bookProgressPercent: Int? {
        guard let total = parsedBook?.totalWords, total > 0 else { return nil }
        let current = playbackManager.currentGlobalWordIndex
        return min(100, max(0, current * 100 / total))
    }

    var body: some View {
        ZStack {
            theme.backgroundColor
                .ignoresSafeArea()

            if let navigator {
                ReadiumReaderView(
                    navigator: navigator,
                    onSpeakFromSelection: { selection in
                        startTTSFromSelection(selection)
                    },
                    onHighlightSelection: { selection in
                        saveHighlight(from: selection)
                    }
                )
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView("Loading book...")
            } else if let loadError {
                errorView(loadError)
            }

            if showControls, navigator != nil {
                controlsOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showControls)
        .preferredColorScheme(theme.colorScheme)
        .task { await loadBook() }
        .onDisappear {
            playbackManager.stop()
            playbackManager.clearCallbacks()
        }
        .onChange(of: playbackManager.isPlaying) { _, playing in
            if playing {
                scheduleHideControls()
                updateWordHighlight() // resume keeps the word index unchanged, so onChange alone won't fire
            }
        }
        .onChange(of: bookStore.readerTheme) { _, newTheme in
            applyThemeToNavigator(newTheme)
        }
        .onChange(of: bookStore.fontSize) { _, newSize in
            applyFontSizeToNavigator(newSize)
        }
        .sheet(isPresented: $showChapterList) {
            chapterListSheet
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(bookStore)
            }
        }
        .sheet(isPresented: $showHighlights) {
            NavigationStack {
                HighlightsView(book: book)
                    .environmentObject(bookStore)
            }
        }
        .onChange(of: showSettings) { _, isShowing in
            if !isShowing { reconfigurePlayback() }
        }
        .onChange(of: showHighlights) { _, isShowing in
            if !isShowing { applyHighlightDecorations() }
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

                if let parsedBook {
                    Text(parsedBook.metadata.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    Button { showHighlights = true } label: {
                        Image(systemName: "highlighter")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 44)
                    }
                    Button { showChapterList = true } label: {
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
                    themeAndFontRow
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

    private var themeAndFontRow: some View {
        HStack(spacing: 8) {
            ForEach(ReaderTheme.allCases, id: \.rawValue) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        bookStore.readerTheme = t
                    }
                } label: {
                    Text(t.label)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(theme == t ? Color.accentColor : Color(.systemGray5))
                        )
                        .foregroundStyle(theme == t ? .white : .primary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    if bookStore.fontSize > 12 { bookStore.fontSize -= 1 }
                } label: {
                    Text("A")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(.systemGray5)))
                        .foregroundStyle(.primary)
                }

                Text("\(Int(bookStore.fontSize))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                Button {
                    if bookStore.fontSize < 32 { bookStore.fontSize += 1 }
                } label: {
                    Text("A")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(.systemGray5)))
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var selectionActionsRow: some View {
        HStack(spacing: 12) {
            if hasTextSelection {
                Button {
                    if let nav = navigator, let sel = nav.currentSelection {
                        startTTSFromSelection(sel)
                    }
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

    // MARK: - Chapter List

    private var chapterListSheet: some View {
        NavigationStack {
            List {
                if let chapters = parsedBook?.chapters {
                    ForEach(chapters, id: \.index) { chapter in
                        Button {
                            navigateToChapter(chapter)
                            showChapterList = false
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
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showChapterList = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentChapterIndex: Int {
        guard let parsedBook else { return -1 }
        let currentParaId = playbackManager.currentParagraphId
        return parsedBook.paragraph(withId: currentParaId)?.chapterIndex ?? -1
    }

    // MARK: - Actions

    private func loadBook() async {
        do {
            let pub = try await ReadiumService.shared.openPublication(at: book.fileURL)
            publication = pub

            let parsed = try await EPUBParserService.shared.parseBook(from: book, publication: pub)
            // Last suspension point: everything below runs synchronously on the
            // MainActor, so this single check closes the race where a dismissed
            // view's loadBook re-registers callbacks onDisappear just cleared
            // (recreating the manager↔view retain cycle with nothing to break it).
            guard !Task.isCancelled else { return }
            parsedBook = parsed

            playbackManager.setBook(paragraphs: parsed.flatParagraphs)
            currentSpeed = bookStore.playbackSpeed
            reconfigurePlayback()

            // Build initial preferences from current theme/font
            let preferences = buildPreferences()

            let lookupAction = EditingAction(
                title: "Look Up",
                action: #selector(ReaderContainerViewController.lookupSelection(_:))
            )
            let highlightAction = EditingAction(
                title: "Highlight",
                action: #selector(ReaderContainerViewController.highlightSelection(_:))
            )
            let speakAction = EditingAction(
                title: "Speak",
                action: #selector(ReaderContainerViewController.speakFromHere(_:))
            )
            let copyAction = EditingAction(
                title: "Copy",
                action: #selector(ReaderContainerViewController.copySelection(_:))
            )
            let nav = try ReadiumService.shared.makeNavigator(
                publication: pub,
                initialLocation: savedLocator(),
                preferences: preferences,
                editingActions: [lookupAction, highlightAction, speakAction, copyAction]
            )

            let delegate = ReaderNavigatorDelegate(
                onTap: { [self] in
                    // Update selection state when controls toggle
                    hasTextSelection = nav.currentSelection != nil
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    if playbackManager.isPlaying && showControls {
                        scheduleHideControls()
                    }
                },
                onLocationChanged: { locator in
                    if let jsonString = locator.jsonString {
                        UserDefaults.standard.set(jsonString, forKey: "locator_\(book.id.uuidString)")
                    }
                },
                onSelectionChanged: { [self] _ in
                    hasTextSelection = nav.currentSelection != nil
                }
            )
            nav.delegate = delegate
            navigatorDelegate = delegate

            let savedPosition = bookStore.getReadingPosition(bookId: book.id)
            if let position = savedPosition {
                let paraIdx = min(position.paragraphIndex, parsed.flatParagraphs.count - 1)
                if paraIdx >= 0 {
                    let para = parsed.flatParagraphs[paraIdx]
                    playbackManager.restorePosition(
                        paragraphArrayIndex: paraIdx,
                        paragraphId: para.id,
                        globalWordIndex: position.globalWordIndex
                    )
                    lastScrolledResourceHref = para.resourceHref
                }
            } else if let firstPara = parsed.flatParagraphs.first {
                lastScrolledResourceHref = firstPara.resourceHref
            }

            navigator = nav
            isLoading = false
            playbackManager.onWordChange = { [self] in
                updateWordHighlight()
            }
            applyHighlightDecorations()
            if savedPosition != nil {
                updateWordHighlight()
            }
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func savedLocator() -> Locator? {
        guard let jsonString = UserDefaults.standard.string(forKey: "locator_\(book.id.uuidString)") else { return nil }
        return try? Locator(jsonString: jsonString)
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

    /// Toggles playback, treating an active selection as an explicit start request.
    private func handlePlayPause() {
        if playbackManager.isPlaying {
            playbackManager.pause()
            return
        }

        if bookStore.activeApiKey.isEmpty || bookStore.activeVoiceId.isEmpty {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        if let nav = navigator,
           let selection = nav.currentSelection {
            guard let startPos = findStartFromSelection(selection) else {
                playbackManager.error = selectionStartErrorMessage
                return
            }

            reconfigurePlayback()
            playbackManager.play(fromParagraphIndex: startPos.paragraphIndex, wordIndex: startPos.wordIndex)
            nav.clearSelection()
            hasTextSelection = false
            return
        }

        reconfigurePlayback()

        // Clamp: a persisted index can go stale if extraction logic changes across app updates.
        let maxIndex = (parsedBook?.flatParagraphs.count ?? 1) - 1
        let position = bookStore.getReadingPosition(bookId: book.id)
        let paragraphIdx = min(max(0, position?.paragraphIndex ?? 0), max(0, maxIndex))
        let wordIdx = position?.globalWordIndex ?? 0
        playbackManager.play(fromParagraphIndex: paragraphIdx, wordIndex: wordIdx)
    }

    /// Starts narration at a Readium selection or reports why it cannot.
    private func startTTSFromSelection(_ selection: Selection) {
        guard !bookStore.activeApiKey.isEmpty, !bookStore.activeVoiceId.isEmpty else {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        guard let startPos = findStartFromSelection(selection) else {
            playbackManager.error = selectionStartErrorMessage
            return
        }

        reconfigurePlayback()
        playbackManager.play(fromParagraphIndex: startPos.paragraphIndex, wordIndex: startPos.wordIndex)
        navigator?.clearSelection()
        hasTextSelection = false
    }

    private func findStartFromSelection(_ selection: Selection) -> (paragraphIndex: Int, wordIndex: Int)? {
        guard let parsedBook else { return nil }
        let selectedText = selection.locator.text.highlight ?? ""
        return TTSHighlightHelper.findStartPosition(
            selectedText: selectedText,
            hrefString: selection.locator.href.string,
            paragraphs: parsedBook.flatParagraphs
        )
    }

    private func navigateToChapter(_ chapter: BookChapter) {
        guard let nav = navigator,
              let firstParagraph = chapter.paragraphs.first,
              let hrefURL = AnyURL(string: firstParagraph.resourceHref) else { return }

        let locator = Locator(
            href: hrefURL,
            mediaType: .xhtml
        )

        lastScrolledResourceHref = firstParagraph.resourceHref

        Task {
            await nav.go(to: locator)
        }

        // Start TTS from chapter start
        if let parsedBook,
           let index = parsedBook.flatParagraphs.firstIndex(where: { $0.id == firstParagraph.id }),
           !bookStore.activeApiKey.isEmpty, !bookStore.activeVoiceId.isEmpty {
            reconfigurePlayback()
            playbackManager.play(fromParagraphIndex: index, wordIndex: firstParagraph.words.first?.id ?? 0)
        }
    }

    // MARK: - Decoration Highlighting

    private func updateWordHighlight() {
        guard let nav = navigator, let parsedBook else { return }
        let wordIndex = playbackManager.currentGlobalWordIndex
        let paraId = playbackManager.currentParagraphId

        guard let paragraph = parsedBook.paragraph(withId: paraId),
              let wordPosition = paragraph.position(ofGlobalWordId: wordIndex),
              let hrefURL = AnyURL(string: paragraph.resourceHref) else {
            nav.apply(decorations: [], in: "tts")
            return
        }
        let ctx = TTSHighlightHelper.buildTextContext(words: paragraph.words, wordPosition: wordPosition)

        let locator = Locator(
            href: hrefURL,
            mediaType: .xhtml,
            text: Locator.Text(
                after: ctx.after,
                before: ctx.before,
                highlight: ctx.highlight
            )
        )

        let decoration = Decoration(
            id: "tts-word",
            locator: locator,
            style: .highlight(tint: .systemBlue, isActive: true)
        )

        nav.apply(decorations: [decoration], in: "tts")

        // Only navigate when the resource (chapter) changes — no auto-scrolling
        if paragraph.resourceHref != lastScrolledResourceHref {
            lastScrolledResourceHref = paragraph.resourceHref
            navigationTask?.cancel()
            navigationTask = Task {
                _ = await nav.go(to: locator, options: NavigatorGoOptions(animated: true))
            }
        }
    }

    private func jumpToCurrentPosition() {
        guard let nav = navigator, let parsedBook else { return }
        let paraId = playbackManager.currentParagraphId
        let wordIndex = playbackManager.currentGlobalWordIndex

        guard let paragraph = parsedBook.paragraph(withId: paraId),
              let hrefURL = AnyURL(string: paragraph.resourceHref) else { return }

        let wordPosition = paragraph.position(ofGlobalWordId: wordIndex) ?? 0
        let ctx = TTSHighlightHelper.buildTextContext(words: paragraph.words, wordPosition: wordPosition)

        let locator = Locator(
            href: hrefURL,
            mediaType: .xhtml,
            text: Locator.Text(
                after: ctx.after,
                before: ctx.before,
                highlight: ctx.highlight
            )
        )

        lastScrolledResourceHref = paragraph.resourceHref
        navigationTask?.cancel()
        navigationTask = Task {
            await nav.go(to: locator, options: NavigatorGoOptions(animated: true))
        }
    }

    // MARK: - Highlights

    private func saveHighlight(from selection: Selection) {
        let text = selection.locator.text.highlight ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let chapterName: String = {
            if let parsedBook {
                let href = selection.locator.href.string
                if let chapter = parsedBook.chapters.first(where: { ch in
                    ch.paragraphs.contains { TTSHighlightHelper.hrefsMatch($0.resourceHref, href) }
                }) {
                    return chapter.title
                }
            }
            return "Unknown Chapter"
        }()

        let highlight = BookHighlight(
            id: UUID(),
            text: text,
            chapterName: chapterName,
            dateCreated: Date(),
            resourceHref: selection.locator.href.string,
            textBefore: selection.locator.text.before,
            textAfter: selection.locator.text.after
        )
        bookStore.addHighlight(highlight, bookId: book.id)
        navigator?.clearSelection()
        applyHighlightDecorations()
    }

    private func applyHighlightDecorations() {
        guard let nav = navigator else { return }
        let highlights = bookStore.getHighlights(bookId: book.id)
        let decorations: [Decoration] = highlights.compactMap { h in
            guard let href = h.resourceHref, let hrefURL = AnyURL(string: href) else { return nil }
            let locator = Locator(
                href: hrefURL,
                mediaType: .xhtml,
                text: Locator.Text(
                    after: h.textAfter,
                    before: h.textBefore,
                    highlight: h.text
                )
            )
            return Decoration(
                id: "hl-\(h.id.uuidString)",
                locator: locator,
                style: .highlight(tint: .yellow, isActive: false)
            )
        }
        nav.apply(decorations: decorations, in: "user-highlights")
    }

    // MARK: - Navigator Preferences

    private func buildPreferences() -> EPUBPreferences {
        let readiumTheme: Theme? = switch bookStore.readerTheme {
        case .light: .light
        case .dark: .dark
        case .sepia: .sepia
        case .system: nil
        }

        return EPUBPreferences(
            fontSize: bookStore.fontSize / 17.0, // Readium uses a scale factor
            scroll: bookStore.isPagedMode ? false : true,
            theme: readiumTheme
        )
    }

    private func applyThemeToNavigator(_ newTheme: ReaderTheme) {
        guard let nav = navigator else { return }
        nav.submitPreferences(buildPreferences())
    }

    private func applyFontSizeToNavigator(_ newSize: Double) {
        guard let nav = navigator else { return }
        nav.submitPreferences(buildPreferences())
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

// MARK: - Navigator Delegate

@MainActor
final class ReaderNavigatorDelegate: NSObject, EPUBNavigatorDelegate {
    private let onTap: () -> Void
    private let onLocationChanged: (Locator) -> Void
    private let onSelectionChanged: ((Selection) -> Void)?

    init(
        onTap: @escaping () -> Void,
        onLocationChanged: @escaping (Locator) -> Void,
        onSelectionChanged: ((Selection) -> Void)? = nil
    ) {
        self.onTap = onTap
        self.onLocationChanged = onLocationChanged
        self.onSelectionChanged = onSelectionChanged
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        onTap()
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChanged(locator)
    }

    func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        onSelectionChanged?(selection)
        return true
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {}
}
