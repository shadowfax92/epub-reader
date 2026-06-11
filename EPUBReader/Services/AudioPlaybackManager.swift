import Foundation
import AVFoundation
import Combine

@MainActor
class AudioPlaybackManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentGlobalWordIndex: Int = 0
    @Published var currentParagraphId: Int = 0
    @Published var isLoadingAudio = false
    @Published var error: String?

    private var audioPlayer: AVAudioPlayer?
    private var wordTimings: [WordTiming] = []
    private var syncTimer: Timer?
    private var allParagraphs: [BookParagraph] = []
    private var currentParagraphArrayIndex: Int = 0

    private var prefetchedAudio: Data?
    private var prefetchedTimings: [WordTiming]?
    private var prefetchedIndex: Int?
    private var prefetchTask: Task<Void, Never>?

    // Cache generated audio to avoid re-spending credits on replayed paragraphs
    private var audioCache: [Int: CachedAudio] = [:]
    private let maxCacheSize = 20

    private var provider: TTSProviderType = .elevenLabs
    private var apiKey: String = ""
    private var voiceId: String = ""
    var speed: Double = 1.0 {
        didSet { audioPlayer?.rate = Float(speed) }
    }

    private var onPositionUpdate: ((ReadingPosition) -> Void)?

    /// Fires on word boundaries straight from the sync timer so the decoration
    /// applies without waiting on a SwiftUI onChange view-update hop; consumers
    /// read the published word/paragraph state, which is set before each fire.
    var onWordChange: (() -> Void)?

    /// Break the manager→closure→view retain cycle when the reader closes:
    /// both callbacks capture the view copy, whose StateObject storage
    /// strongly retains this manager.
    func clearCallbacks() {
        onWordChange = nil
        onPositionUpdate = nil
    }

    private struct CachedAudio {
        let audioData: Data
        let timings: [WordTiming]
    }

    func configure(provider: TTSProviderType, apiKey: String, voiceId: String, speed: Double, onPositionUpdate: @escaping (ReadingPosition) -> Void) {
        let providerChanged = self.provider != provider
        let voiceChanged = self.voiceId != voiceId
        self.provider = provider
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.speed = speed
        self.onPositionUpdate = onPositionUpdate
        if voiceChanged || providerChanged {
            audioCache.removeAll()
        }
        configureAudioSession()
        setupInterruptionHandling()
    }

    func setBook(paragraphs: [BookParagraph]) {
        self.allParagraphs = paragraphs
        audioCache.removeAll()
    }

    func play(fromParagraphIndex index: Int, wordIndex: Int = 0) {
        // Stop playback but preserve prefetched audio
        saveCurrentPosition()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        stopSyncTimer()

        currentParagraphArrayIndex = index
        Task { await generateAndPlay(paragraphIndex: index, startFromWordGlobal: wordIndex) }
    }

    func playFromGlobalWord(_ globalWordIndex: Int) {
        guard let paragraphIndex = allParagraphs.indexOfParagraph(containingWordId: globalWordIndex) else { return }
        play(fromParagraphIndex: paragraphIndex, wordIndex: globalWordIndex)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopSyncTimer()
        saveCurrentPosition()
    }

    func resume() {
        guard let player = audioPlayer else {
            play(fromParagraphIndex: currentParagraphArrayIndex)
            return
        }
        player.play()
        isPlaying = true
        startSyncTimer()
    }

    func skip(seconds: Double) {
        guard let player = audioPlayer else { return }
        let newTime = player.currentTime + seconds
        if newTime < 0 {
            if currentParagraphArrayIndex > 0 {
                play(fromParagraphIndex: currentParagraphArrayIndex - 1)
            } else {
                player.currentTime = 0
                updateHighlight()
            }
        } else if newTime >= player.duration {
            advanceToNext()
        } else {
            player.currentTime = newTime
            updateHighlight()
        }
    }

    func stop() {
        saveCurrentPosition()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        stopSyncTimer()
        prefetchTask?.cancel()
        prefetchedAudio = nil
        prefetchedTimings = nil
    }

    // MARK: - Private

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt

            guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            Task { @MainActor in
                if type == .began {
                    self.pause()
                } else if type == .ended {
                    if let optionsValue {
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        if options.contains(.shouldResume) {
                            self.resume()
                        }
                    }
                }
            }
        }
    }

    private func paragraphText(at index: Int) -> String? {
        guard index >= 0, index < allParagraphs.count else { return nil }
        let text = allParagraphs[index].words.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func generateAndPlay(paragraphIndex: Int, startFromWordGlobal: Int = 0) async {
        var idx = paragraphIndex

        while idx < allParagraphs.count {
            let text = allParagraphs[idx].words.map(\.text).joined(separator: " ")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            idx += 1
        }

        guard idx < allParagraphs.count else {
            isPlaying = false
            isLoadingAudio = false
            return
        }

        guard !apiKey.isEmpty, !voiceId.isEmpty else {
            error = "Please set your API key and voice in Settings."
            isPlaying = false
            isLoadingAudio = false
            return
        }

        currentParagraphArrayIndex = idx
        let paragraph = allParagraphs[idx]

        // Check cache first — no API call needed
        if let cached = audioCache[paragraph.id] {
            do {
                try startPlayback(
                    audioData: cached.audioData,
                    timings: cached.timings,
                    paragraphIndex: idx,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: startFromWordGlobal
                )
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: idx + 1) }
                return
            } catch {
                audioCache.removeValue(forKey: paragraph.id)
            }
        }

        // Check prefetch
        if let cachedAudio = prefetchedAudio,
           let cachedTimings = prefetchedTimings,
           prefetchedIndex == idx {
            prefetchedAudio = nil
            prefetchedTimings = nil
            prefetchedIndex = nil

            cacheAudio(audioData: cachedAudio, timings: cachedTimings, paragraphId: paragraph.id)

            do {
                try startPlayback(
                    audioData: cachedAudio,
                    timings: cachedTimings,
                    paragraphIndex: idx,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: startFromWordGlobal
                )
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: idx + 1) }
                return
            } catch {
                self.error = "Playback error: \(error.localizedDescription)"
                isPlaying = false
                return
            }
        }

        isLoadingAudio = true
        error = nil

        let text = paragraph.words.map(\.text).joined(separator: " ")

        do {
            let (audioData, timings) = try await generateAudio(
                text: text,
                words: paragraph.words,
                paragraphIndex: idx
            )

            cacheAudio(audioData: audioData, timings: timings, paragraphId: paragraph.id)

            try startPlayback(
                audioData: audioData,
                timings: timings,
                paragraphIndex: idx,
                paragraphId: paragraph.id,
                startFromWordGlobal: startFromWordGlobal
            )

            isLoadingAudio = false

            prefetchTask?.cancel()
            prefetchTask = Task { await prefetchNext(paragraphIndex: idx + 1) }

        } catch {
            isLoadingAudio = false
            isPlaying = false
            self.error = error.localizedDescription
        }
    }

    private func cacheAudio(audioData: Data, timings: [WordTiming], paragraphId: Int) {
        if audioCache.count >= maxCacheSize {
            if let oldest = audioCache.keys.min() {
                audioCache.removeValue(forKey: oldest)
            }
        }
        audioCache[paragraphId] = CachedAudio(audioData: audioData, timings: timings)
    }

    private func startPlayback(audioData: Data, timings: [WordTiming], paragraphIndex: Int, paragraphId: Int, startFromWordGlobal: Int) throws {
        audioPlayer?.stop()
        audioPlayer = try AVAudioPlayer(data: audioData)
        audioPlayer?.enableRate = true
        audioPlayer?.rate = Float(speed)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        wordTimings = timings
        currentParagraphArrayIndex = paragraphIndex
        currentParagraphId = paragraphId

        if startFromWordGlobal > 0, let timing = timings.first(where: { $0.globalWordIndex >= startFromWordGlobal }) {
            audioPlayer?.currentTime = timing.startTime
        }

        if let firstWord = allParagraphs[paragraphIndex].words.first {
            currentGlobalWordIndex = startFromWordGlobal > 0 ? startFromWordGlobal : firstWord.id
            // Unconditional fire: resuming on the same word produces no
            // index change, but the decoration still needs an initial draw.
            onWordChange?()
        }

        audioPlayer?.play()
        isPlaying = true
        startSyncTimer()
    }

    private func startSyncTimer() {
        stopSyncTimer()
        // .common keeps ticks flowing while the WKWebView scroll view is
        // tracking — .default-mode timers pause and the highlight freezes
        // mid-scroll. assumeIsolated (valid: main-run-loop timers fire on the
        // main thread) avoids allocating a Task per tick.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHighlight()
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func updateHighlight() {
        guard let player = audioPlayer, player.isPlaying else { return }
        let currentTime = player.currentTime

        let index = TTSTimingMapper.currentWordIndex(timings: wordTimings, at: currentTime)
            ?? wordTimings.first?.globalWordIndex
        if let index, index != currentGlobalWordIndex {
            currentGlobalWordIndex = index
            onWordChange?()
        }
    }

    private func advanceToNext() {
        stopSyncTimer()
        var nextIndex = currentParagraphArrayIndex + 1

        while nextIndex < allParagraphs.count && allParagraphs[nextIndex].words.isEmpty {
            nextIndex += 1
        }

        guard nextIndex < allParagraphs.count else {
            isPlaying = false
            saveCurrentPosition()
            return
        }

        let paragraph = allParagraphs[nextIndex]

        // Check cache first
        if let cached = audioCache[paragraph.id] {
            do {
                try startPlayback(
                    audioData: cached.audioData,
                    timings: cached.timings,
                    paragraphIndex: nextIndex,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: 0
                )
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: nextIndex + 1) }
                return
            } catch {
                audioCache.removeValue(forKey: paragraph.id)
            }
        }

        // Check prefetch
        if let cachedAudio = prefetchedAudio,
           let cachedTimings = prefetchedTimings,
           prefetchedIndex == nextIndex {
            prefetchedAudio = nil
            prefetchedTimings = nil
            prefetchedIndex = nil

            cacheAudio(audioData: cachedAudio, timings: cachedTimings, paragraphId: paragraph.id)

            do {
                try startPlayback(
                    audioData: cachedAudio,
                    timings: cachedTimings,
                    paragraphIndex: nextIndex,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: 0
                )
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: nextIndex + 1) }
            } catch {
                self.error = "Playback error: \(error.localizedDescription)"
                isPlaying = false
            }
        } else {
            Task { await generateAndPlay(paragraphIndex: nextIndex) }
        }
    }

    private func prefetchNext(paragraphIndex: Int) async {
        var idx = paragraphIndex
        while idx < allParagraphs.count && allParagraphs[idx].words.isEmpty {
            idx += 1
        }
        guard idx < allParagraphs.count else { return }

        let paragraph = allParagraphs[idx]

        if audioCache[paragraph.id] != nil { return }

        let text = paragraph.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }

        do {
            let (audioData, timings) = try await generateAudio(
                text: text,
                words: paragraph.words,
                paragraphIndex: idx
            )

            cacheAudio(audioData: audioData, timings: timings, paragraphId: paragraph.id)
            prefetchedAudio = audioData
            prefetchedTimings = timings
            prefetchedIndex = idx
        } catch {
            // Prefetch failure is non-critical
        }
    }

    // MARK: - Provider-Aware Audio Generation

    private func generateAudio(text: String, words: [BookWord], paragraphIndex: Int) async throws -> (Data, [WordTiming]) {
        switch provider {
        case .elevenLabs:
            let response = try await ElevenLabsService.shared.generateSpeech(
                text: text,
                voiceId: voiceId,
                apiKey: apiKey,
                previousText: paragraphText(at: paragraphIndex - 1),
                nextText: paragraphText(at: paragraphIndex + 1)
            )
            // Raw alignment's characters match the input text exactly;
            // normalized_alignment expands numbers/abbreviations and drifts.
            let alignment = [response.alignment, response.normalized_alignment]
                .compactMap { $0 }
                .first { !$0.characters.isEmpty }
            let timings = TTSTimingMapper.mapAlignment(
                characters: alignment?.characters ?? [],
                startTimes: alignment?.character_start_times_seconds ?? [],
                endTimes: alignment?.character_end_times_seconds ?? [],
                words: words
            )
            guard let audioData = Data(base64Encoded: response.audio_base64) else {
                throw ElevenLabsError.invalidResponse
            }
            return (audioData, timings)

        case .openAI:
            let audioData = try await OpenAITTSService.shared.generateSpeech(
                text: text,
                voiceId: voiceId,
                apiKey: apiKey
            )
            let timings = estimateWordTimings(words: words, audioData: audioData)
            return (audioData, timings)
        }
    }

    private func estimateWordTimings(words: [BookWord], audioData: Data) -> [WordTiming] {
        guard let tempPlayer = try? AVAudioPlayer(data: audioData) else { return [] }
        return TTSTimingMapper.proportionalTimings(words: words, duration: tempPlayer.duration)
    }

    private func saveCurrentPosition() {
        guard !allParagraphs.isEmpty else { return }
        let paragraphIndex = currentParagraphArrayIndex
        guard paragraphIndex < allParagraphs.count else { return }
        let paragraph = allParagraphs[paragraphIndex]

        onPositionUpdate?(ReadingPosition(
            chapterIndex: paragraph.chapterIndex,
            paragraphIndex: paragraphIndex,
            globalWordIndex: currentGlobalWordIndex
        ))
    }
}

extension AudioPlaybackManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.advanceToNext()
        }
    }
}
