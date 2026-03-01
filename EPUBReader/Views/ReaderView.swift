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

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        ZStack {
            Color(.systemBackground)
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
                    .allowsHitTesting(true)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showControls)
        .ignoresSafeArea(edges: showControls ? [] : .all)
        .task { await loadBook() }
        .onDisappear {
            playbackManager.stop()
        }
        .onChange(of: playbackManager.isPlaying) { _, playing in
            if playing {
                scheduleHideControls()
            }
        }
    }

    // MARK: - Reading Content

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
            }
            .onChange(of: playbackManager.currentParagraphId) { _, newId in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(newId, anchor: .top)
                }
            }
            .onAppear {
                if !initialScrollDone {
                    initialScrollDone = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if playbackManager.currentParagraphId > 0 {
                            proxy.scrollTo(playbackManager.currentParagraphId, anchor: .top)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls && playbackManager.isPlaying {
                    scheduleHideControls()
                }
            }
        }
    }

    private func paragraphView(_ paragraph: BookParagraph) -> some View {
        Text(makeAttributedString(paragraph: paragraph))
            .font(paragraph.isHeading ? .title2.bold() : .body)
            .lineSpacing(paragraph.isHeading ? 4 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func makeAttributedString(paragraph: BookParagraph) -> AttributedString {
        var result = AttributedString()
        let highlightIndex = playbackManager.currentGlobalWordIndex
        let isActive = playbackManager.isPlaying || playbackManager.isLoadingAudio

        for (i, word) in paragraph.words.enumerated() {
            var wordAttr = AttributedString(word.text)

            if word.id == highlightIndex && isActive {
                wordAttr.backgroundColor = Color.accentColor.opacity(0.25)
                wordAttr.foregroundColor = Color.accentColor
                wordAttr.font = paragraph.isHeading ? .title2.bold() : .body.bold()
            }

            result.append(wordAttr)

            if i < paragraph.words.count - 1 {
                result.append(AttributedString(" "))
            }
        }

        return result
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack {
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

                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .background(.ultraThinMaterial)

            Spacer()

            VStack(spacing: 16) {
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

    // MARK: - Actions

    private func loadBook() async {
        do {
            let parsed = try EPUBParserService.shared.parseBook(from: book)
            parsedBook = parsed

            playbackManager.setBook(paragraphs: parsed.flatParagraphs)
            currentSpeed = bookStore.playbackSpeed

            playbackManager.configure(
                apiKey: bookStore.apiKey,
                voiceId: bookStore.selectedVoiceId,
                speed: currentSpeed,
                onPositionUpdate: { position in
                    bookStore.saveReadingPosition(bookId: book.id, position: position)
                }
            )

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

    private func handlePlayPause() {
        if playbackManager.isPlaying {
            playbackManager.pause()
            return
        }

        if bookStore.apiKey.isEmpty || bookStore.selectedVoiceId.isEmpty {
            playbackManager.error = "Set your API key and voice in Settings first."
            return
        }

        playbackManager.configure(
            apiKey: bookStore.apiKey,
            voiceId: bookStore.selectedVoiceId,
            speed: currentSpeed,
            onPositionUpdate: { position in
                bookStore.saveReadingPosition(bookId: book.id, position: position)
            }
        )

        let position = bookStore.getReadingPosition(bookId: book.id)
        let paragraphIdx = position?.paragraphIndex ?? 0
        let wordIdx = position?.globalWordIndex ?? 0
        playbackManager.play(fromParagraphIndex: paragraphIdx, wordIndex: wordIdx)
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
