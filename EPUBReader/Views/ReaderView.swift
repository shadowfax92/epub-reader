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
    @State private var navigatorDelegate: ReaderNavigatorDelegate?

    private let speedOptions: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.5]

    private var theme: ReaderTheme { bookStore.readerTheme }

    var body: some View {
        ZStack {
            theme.backgroundColor
                .ignoresSafeArea()

            if let navigator {
                ReadiumReaderView(navigator: navigator)
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

            let nav = try ReadiumService.shared.makeNavigator(
                publication: pub,
                initialLocation: savedLocator(),
                preferences: preferences
            )

            let delegate = ReaderNavigatorDelegate(
                onTap: { [self] in
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
                }
            )
            nav.delegate = delegate
            navigatorDelegate = delegate

            if let position = bookStore.getReadingPosition(bookId: book.id) {
                playbackManager.currentGlobalWordIndex = position.globalWordIndex
                let paraIdx = min(position.paragraphIndex, parsed.flatParagraphs.count - 1)
                if paraIdx >= 0 {
                    playbackManager.currentParagraphId = parsed.flatParagraphs[paraIdx].id
                }
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

        let position = bookStore.getReadingPosition(bookId: book.id)
        let paragraphIdx = position?.paragraphIndex ?? 0
        let wordIdx = position?.globalWordIndex ?? 0
        playbackManager.play(fromParagraphIndex: paragraphIdx, wordIndex: wordIdx)
    }

    private func navigateToChapter(_ chapter: BookChapter) {
        guard let nav = navigator,
              let firstParagraph = chapter.paragraphs.first,
              let hrefURL = AnyURL(string: firstParagraph.resourceHref) else { return }

        let locator = Locator(
            href: hrefURL,
            mediaType: .xhtml
        )
        Task {
            await nav.go(to: locator)
        }

        // Also start TTS from chapter start
        if let parsedBook,
           let index = parsedBook.flatParagraphs.firstIndex(where: { $0.id == firstParagraph.id }) {
            if playbackManager.isPlaying {
                reconfigurePlayback()
                playbackManager.play(fromParagraphIndex: index, wordIndex: firstParagraph.words.first?.id ?? 0)
            }
        }
    }

    // MARK: - Decoration Highlighting

    private func updateWordHighlight() {
        guard let nav = navigator, let parsedBook else { return }
        let wordIndex = playbackManager.currentGlobalWordIndex
        let paraId = playbackManager.currentParagraphId

        guard let paragraph = parsedBook.flatParagraphs.first(where: { $0.id == paraId }),
              let word = paragraph.words.first(where: { $0.id == wordIndex }),
              let hrefURL = AnyURL(string: paragraph.resourceHref) else {
            nav.apply(decorations: [], in: "tts")
            return
        }

        let wordPosition = paragraph.words.firstIndex(where: { $0.id == wordIndex }) ?? 0
        let beforeWords = paragraph.words.prefix(wordPosition).suffix(8)
        let afterWords = paragraph.words.dropFirst(wordPosition + 1).prefix(8)

        let beforeText = beforeWords.map(\.text).joined(separator: " ")
        let afterText = afterWords.map(\.text).joined(separator: " ")

        let locator = Locator(
            href: hrefURL,
            mediaType: .xhtml,
            text: Locator.Text(
                after: afterText.isEmpty ? nil : afterText,
                before: beforeText.isEmpty ? nil : beforeText,
                highlight: word.text
            )
        )

        let decoration = Decoration(
            id: "tts-word",
            locator: locator,
            style: .highlight(tint: .systemBlue, isActive: true)
        )

        nav.apply(decorations: [decoration], in: "tts")

        // Navigate the reader to follow TTS
        Task {
            await nav.go(to: locator, options: NavigatorGoOptions(animated: true))
        }
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

    init(onTap: @escaping () -> Void, onLocationChanged: @escaping (Locator) -> Void) {
        self.onTap = onTap
        self.onLocationChanged = onLocationChanged
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        onTap()
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        onLocationChanged(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {}
}
