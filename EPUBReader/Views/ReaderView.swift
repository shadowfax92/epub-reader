import SwiftUI

struct ReaderView: View {
    let book: BookMetadata
    @EnvironmentObject var bookStore: BookStore
    @StateObject private var playbackManager = AudioPlaybackManager()
    @Environment(\.dismiss) private var dismiss

    @State private var parsedBook: ParsedBook?
    @State private var showControls = true
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var currentSpeed: Double = 1.0
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var initialScrollDone = false
    @State private var showChapterList = false
    @State private var showSettings = false
    @State private var pendingScrollTarget: Int?

    private let speedOptions: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.5]

    private var theme: ReaderTheme { bookStore.readerTheme }

    var body: some View {
        ZStack {
            theme.backgroundColor
                .ignoresSafeArea()

            if let parsedBook {
                readingContent(parsedBook)
            } else if isLoading {
                ProgressView("Loading book...")
            } else if let loadError {
                errorView(loadError)
            }

            if showControls, parsedBook != nil {
                controlsOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showControls)
        .ignoresSafeArea(edges: showControls ? [] : .all)
        .preferredColorScheme(theme.colorScheme)
        .task { await loadBook() }
        .onDisappear {
            playbackManager.stop()
        }
        .onChange(of: playbackManager.isPlaying) { _, playing in
            if playing { scheduleHideControls() }
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

    // MARK: - Reading Content

    @ViewBuilder
    private func readingContent(_ book: ParsedBook) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(book.flatParagraphs) { paragraph in
                        paragraphView(paragraph)
                            .id(paragraph.id)
                    }

                    Spacer().frame(height: 140)
                }
                .padding(.horizontal, 20)
                .padding(.top, 60)
                .scrollTargetLayout()
            }
            .applyPagedScroll(bookStore.isPagedMode)
            .onChange(of: playbackManager.currentParagraphId) { _, newId in
                // Gentle scroll: position paragraph at ~30% from top, slower animation
                withAnimation(.easeInOut(duration: 0.7)) {
                    proxy.scrollTo(newId, anchor: UnitPoint(x: 0.5, y: 0.3))
                }
            }
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                pendingScrollTarget = nil
            }
            .onAppear {
                if !initialScrollDone {
                    initialScrollDone = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if playbackManager.currentParagraphId > 0 {
                            proxy.scrollTo(playbackManager.currentParagraphId, anchor: UnitPoint(x: 0.5, y: 0.3))
                        }
                    }
                }
            }
        }
    }

    private func paragraphView(_ paragraph: BookParagraph) -> some View {
        let isActive = (playbackManager.isPlaying || playbackManager.isLoadingAudio)
            && paragraph.id == playbackManager.currentParagraphId

        let content: Text = if isActive {
            Text(makeHighlightedString(paragraph: paragraph))
        } else {
            Text(paragraph.text)
        }

        return content
            .font(paragraph.isHeading ?
                  .system(size: bookStore.fontSize + 6, weight: .bold) :
                  .system(size: bookStore.fontSize))
            .foregroundStyle(theme.textColor)
            .lineSpacing(paragraph.isHeading ? 4 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                if !showControls {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls = true
                    }
                    if playbackManager.isPlaying {
                        scheduleHideControls()
                    }
                } else {
                    handleParagraphTap(paragraph)
                }
            }
    }

    private func makeHighlightedString(paragraph: BookParagraph) -> AttributedString {
        var result = AttributedString()
        let highlightIndex = playbackManager.currentGlobalWordIndex
        let textColor = theme.textColor

        for (i, word) in paragraph.words.enumerated() {
            var wordAttr = AttributedString(word.text)
            wordAttr.foregroundColor = textColor

            if word.id == highlightIndex {
                wordAttr.backgroundColor = Color.accentColor.opacity(0.25)
                wordAttr.foregroundColor = Color.accentColor
                wordAttr.font = paragraph.isHeading ?
                    .system(size: bookStore.fontSize + 6, weight: .bold) :
                    .system(size: bookStore.fontSize, weight: .semibold)
            }

            result.append(wordAttr)

            if i < paragraph.words.count - 1 {
                var space = AttributedString(" ")
                space.foregroundColor = textColor
                result.append(space)
            }
        }

        return result
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            // Top bar
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

            // Bottom controls
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

                    // Font size controls
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
                            if let targetId = chapter.paragraphs.first?.id {
                                pendingScrollTarget = targetId
                            }
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
            let parsed = try EPUBParserService.shared.parseBook(from: book)
            parsedBook = parsed

            playbackManager.setBook(paragraphs: parsed.flatParagraphs)
            currentSpeed = bookStore.playbackSpeed

            reconfigurePlayback()

            if let position = bookStore.getReadingPosition(bookId: book.id) {
                playbackManager.currentGlobalWordIndex = position.globalWordIndex
                let paraIdx = min(position.paragraphIndex, parsed.flatParagraphs.count - 1)
                if paraIdx >= 0 {
                    playbackManager.currentParagraphId = parsed.flatParagraphs[paraIdx].id
                }
            }

            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
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

    private func handleParagraphTap(_ paragraph: BookParagraph) {
        guard let parsedBook else { return }
        guard let index = parsedBook.flatParagraphs.firstIndex(where: { $0.id == paragraph.id }) else { return }

        if bookStore.apiKey.isEmpty || bookStore.selectedVoiceId.isEmpty {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        reconfigurePlayback()

        let firstWordId = paragraph.words.first?.id ?? 0
        playbackManager.play(fromParagraphIndex: index, wordIndex: firstWordId)
        scheduleHideControls()
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

// MARK: - Paged Scroll Modifier

extension View {
    @ViewBuilder
    func applyPagedScroll(_ isPaged: Bool) -> some View {
        if isPaged {
            self.scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }
}
