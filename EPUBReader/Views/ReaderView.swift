import SwiftUI
import ReadiumShared
import ReadiumNavigator

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

    private let speedOptions: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.5]

    private var theme: ReaderTheme { bookStore.readerTheme }

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
        }
        .onChange(of: playbackManager.isPlaying) { _, playing in
            if playing { scheduleHideControls() }
        }
        .onChange(of: playbackManager.currentGlobalWordIndex) { _, _ in
            updateWordHighlight()
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

                if playbackManager.isLoadingAudio {
                    ProgressView()
                        .tint(Color.accentColor)
                }

                if let error = playbackManager.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Theme pills
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

                // Speed pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(speedOptions, id: \.self) { speed in
                            Button {
                                currentSpeed = speed
                                playbackManager.speed = speed
                                bookStore.playbackSpeed = speed
                            } label: {
                                Text(formatSpeed(speed))
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(currentSpeed == speed ? Color.accentColor : Color(.systemGray5))
                                    )
                                    .foregroundStyle(currentSpeed == speed ? .white : .primary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

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

                // Playback controls
                HStack(spacing: 36) {
                    Button { playbackManager.skip(seconds: -10) } label: {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                    }

                    Button { handlePlayPause() } label: {
                        Image(systemName: playbackManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.accentColor)
                    }

                    Button { playbackManager.skip(seconds: 10) } label: {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                    }
                }

                Spacer().frame(height: 8)
            }
            .padding(.vertical, 16)
            .background(.ultraThinMaterial)
        }
        .transition(.opacity)
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
        return parsedBook.flatParagraphs.first(where: { $0.id == currentParaId })?.chapterIndex ?? -1
    }

    // MARK: - Actions

    private func loadBook() async {
        do {
            let pub = try await ReadiumService.shared.openPublication(at: book.fileURL)
            publication = pub

            let parsed = try await EPUBParserService.shared.parseBook(from: book, publication: pub)
            parsedBook = parsed

            playbackManager.setBook(paragraphs: parsed.flatParagraphs)
            currentSpeed = bookStore.playbackSpeed
            reconfigurePlayback()

            // Build initial preferences from current theme/font
            let preferences = buildPreferences()

            let highlightAction = EditingAction(
                title: "Highlight",
                action: #selector(ReaderContainerViewController.highlightSelection(_:))
            )
            let speakAction = EditingAction(
                title: "Speak from Here",
                action: #selector(ReaderContainerViewController.speakFromHere(_:))
            )
            let nav = try ReadiumService.shared.makeNavigator(
                publication: pub,
                initialLocation: savedLocator(),
                preferences: preferences,
                editingActions: [.copy, highlightAction, speakAction]
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

            if let position = bookStore.getReadingPosition(bookId: book.id) {
                playbackManager.currentGlobalWordIndex = position.globalWordIndex
                let paraIdx = min(position.paragraphIndex, parsed.flatParagraphs.count - 1)
                if paraIdx >= 0 {
                    let para = parsed.flatParagraphs[paraIdx]
                    playbackManager.currentParagraphId = para.id
                    lastScrolledResourceHref = para.resourceHref
                }
            } else if let firstPara = parsed.flatParagraphs.first {
                lastScrolledResourceHref = firstPara.resourceHref
            }

            navigator = nav
            isLoading = false
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
            apiKey: bookStore.apiKey,
            voiceId: bookStore.selectedVoiceId,
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

        if bookStore.apiKey.isEmpty || bookStore.selectedVoiceId.isEmpty {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        reconfigurePlayback()

        // Check for text selection to start TTS from that point
        if let nav = navigator,
           let selection = nav.currentSelection,
           let startPos = findStartFromSelection(selection) {
            playbackManager.play(fromParagraphIndex: startPos.paragraphIndex, wordIndex: startPos.wordIndex)
            nav.clearSelection()
            hasTextSelection = false
            return
        }

        let position = bookStore.getReadingPosition(bookId: book.id)
        let paragraphIdx = position?.paragraphIndex ?? 0
        let wordIdx = position?.globalWordIndex ?? 0
        playbackManager.play(fromParagraphIndex: paragraphIdx, wordIndex: wordIdx)
    }

    private func startTTSFromSelection(_ selection: Selection) {
        guard !bookStore.apiKey.isEmpty, !bookStore.selectedVoiceId.isEmpty else {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        guard let startPos = findStartFromSelection(selection) else { return }

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
           !bookStore.apiKey.isEmpty, !bookStore.selectedVoiceId.isEmpty {
            reconfigurePlayback()
            playbackManager.play(fromParagraphIndex: index, wordIndex: firstParagraph.words.first?.id ?? 0)
        }
    }

    // MARK: - Decoration Highlighting

    private func updateWordHighlight() {
        guard let nav = navigator, let parsedBook else { return }
        let wordIndex = playbackManager.currentGlobalWordIndex
        let paraId = playbackManager.currentParagraphId

        guard let paragraph = parsedBook.flatParagraphs.first(where: { $0.id == paraId }),
              paragraph.words.contains(where: { $0.id == wordIndex }),
              let hrefURL = AnyURL(string: paragraph.resourceHref) else {
            nav.apply(decorations: [], in: "tts")
            return
        }

        let wordPosition = paragraph.words.firstIndex(where: { $0.id == wordIndex }) ?? 0
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

        #if DEBUG
        print("[TTS-HL] word='\(ctx.highlight)' para=\(paraId) href=\(paragraph.resourceHref) before=\(ctx.before?.count ?? 0)ch after=\(ctx.after?.count ?? 0)ch")
        #endif

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

        guard let paragraph = parsedBook.flatParagraphs.first(where: { $0.id == paraId }),
              let hrefURL = AnyURL(string: paragraph.resourceHref) else { return }

        let wordPosition = paragraph.words.firstIndex(where: { $0.id == wordIndex }) ?? 0
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
            dateCreated: Date()
        )
        bookStore.addHighlight(highlight, bookId: book.id)
        navigator?.clearSelection()
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

    private func formatSpeed(_ speed: Double) -> String {
        if speed == Double(Int(speed)) {
            return "\(Int(speed)).0x"
        }
        return String(format: "%.2gx", speed)
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
