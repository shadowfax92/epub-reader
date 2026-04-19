import AVFoundation
import Combine
import Foundation

@MainActor
class AudioPlaybackManager: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentGlobalWordIndex: Int = 0
    @Published var currentParagraphId: Int = 0
    @Published var isLoadingAudio = false
    @Published var error: String?

    private var audioPlayer: AVAudioPlayer?
    private var wordTimings: [PlaybackHighlightTiming] = []
    private var syncTimer: Timer?
    private var allParagraphs: [BookParagraph] = []
    private var currentParagraphArrayIndex: Int = 0
    private var resolvedGlobalWordIndex: Int = 0
    private var resolvedTimingIndex: Int = 0
    private var lastPublishedHighlightTime = -Double.greatestFiniteMagnitude

    private var prefetchedAudio: Data?
    private var prefetchedTimings: [PlaybackHighlightTiming]?
    private var prefetchedIndex: Int?
    private var prefetchTask: Task<Void, Never>?

    private var audioCache: [Int: CachedAudio] = [:]
    private let maxCacheSize = 20
    private let minimumHighlightUpdateInterval = 0.1

    private var provider: TTSProviderType = .elevenLabs
    private var apiKey: String = ""
    private var voiceId: String = ""
    private var onPositionUpdate: ((ReadingPosition) -> Void)?

    var speed: Double = 1.0 {
        didSet { audioPlayer?.rate = Float(speed) }
    }

    var currentPlaybackWordIndex: Int {
        resolvedGlobalWordIndex > 0 ? resolvedGlobalWordIndex : currentGlobalWordIndex
    }

    private struct CachedAudio {
        let audioData: Data
        let timings: [PlaybackHighlightTiming]
    }

    func configure(
        provider: TTSProviderType,
        apiKey: String,
        voiceId: String,
        speed: Double,
        onPositionUpdate: @escaping (ReadingPosition) -> Void
    ) {
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
        allParagraphs = paragraphs
        audioCache.removeAll()
        resolvedGlobalWordIndex = 0
        resolvedTimingIndex = 0
        lastPublishedHighlightTime = -Double.greatestFiniteMagnitude
    }

    func play(fromParagraphIndex index: Int, wordIndex: Int = 0) {
        saveCurrentPosition()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        stopSyncTimer()

        currentParagraphArrayIndex = index
        Task { await generateAndPlay(paragraphIndex: index, startFromWordGlobal: wordIndex) }
    }

    func playFromGlobalWord(_ globalWordIndex: Int) {
        guard let paragraphIndex = allParagraphs.firstIndex(where: { paragraph in
            paragraph.words.contains(where: { $0.id == globalWordIndex })
        }) else { return }
        play(fromParagraphIndex: paragraphIndex, wordIndex: globalWordIndex)
    }

    func togglePlayback() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopSyncTimer()
        updateHighlight(force: true)
        saveCurrentPosition()
    }

    func resume() {
        guard let player = audioPlayer else {
            play(fromParagraphIndex: currentParagraphArrayIndex, wordIndex: currentPlaybackWordIndex)
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
                updateHighlight(force: true)
            }
        } else if newTime >= player.duration {
            advanceToNext()
        } else {
            player.currentTime = newTime
            updateHighlight(force: true)
        }
    }

    func stop() {
        updateHighlight(force: true)
        saveCurrentPosition()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        stopSyncTimer()
        prefetchTask?.cancel()
        prefetchedAudio = nil
        prefetchedTimings = nil
        prefetchedIndex = nil
    }

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

            guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            Task { @MainActor in
                if type == .began {
                    self.pause()
                } else if type == .ended, let optionsValue {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) {
                        self.resume()
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
        var index = paragraphIndex

        while index < allParagraphs.count {
            let text = allParagraphs[index].words.map(\.text).joined(separator: " ")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            index += 1
        }

        guard index < allParagraphs.count else {
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

        currentParagraphArrayIndex = index
        let paragraph = allParagraphs[index]

        if let cached = audioCache[paragraph.id] {
            do {
                try startPlayback(
                    audioData: cached.audioData,
                    timings: cached.timings,
                    paragraphIndex: index,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: startFromWordGlobal
                )
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: index + 1) }
                return
            } catch {
                audioCache.removeValue(forKey: paragraph.id)
            }
        }

        if let cachedAudio = prefetchedAudio,
           let cachedTimings = prefetchedTimings,
           prefetchedIndex == index {
            prefetchedAudio = nil
            prefetchedTimings = nil
            prefetchedIndex = nil
            cacheAudio(audioData: cachedAudio, timings: cachedTimings, paragraphId: paragraph.id)

            do {
                try startPlayback(
                    audioData: cachedAudio,
                    timings: cachedTimings,
                    paragraphIndex: index,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: startFromWordGlobal
                )
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: index + 1) }
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
                paragraphIndex: index
            )
            cacheAudio(audioData: audioData, timings: timings, paragraphId: paragraph.id)
            try startPlayback(
                audioData: audioData,
                timings: timings,
                paragraphIndex: index,
                paragraphId: paragraph.id,
                startFromWordGlobal: startFromWordGlobal
            )
            isLoadingAudio = false
            prefetchTask?.cancel()
            prefetchTask = Task { await prefetchNext(paragraphIndex: index + 1) }
        } catch {
            isLoadingAudio = false
            isPlaying = false
            self.error = error.localizedDescription
        }
    }

    private func cacheAudio(audioData: Data, timings: [PlaybackHighlightTiming], paragraphId: Int) {
        if audioCache.count >= maxCacheSize, let oldest = audioCache.keys.min() {
            audioCache.removeValue(forKey: oldest)
        }
        audioCache[paragraphId] = CachedAudio(audioData: audioData, timings: timings)
    }

    private func startPlayback(
        audioData: Data,
        timings: [PlaybackHighlightTiming],
        paragraphIndex: Int,
        paragraphId: Int,
        startFromWordGlobal: Int
    ) throws {
        audioPlayer?.stop()
        audioPlayer = try AVAudioPlayer(data: audioData)
        audioPlayer?.enableRate = true
        audioPlayer?.rate = Float(speed)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()

        wordTimings = timings
        currentParagraphArrayIndex = paragraphIndex
        currentParagraphId = paragraphId
        resolvedTimingIndex = 0
        lastPublishedHighlightTime = -Double.greatestFiniteMagnitude

        if startFromWordGlobal > 0,
           let timingIndex = timings.firstIndex(where: { $0.globalWordIndex >= startFromWordGlobal }) {
            audioPlayer?.currentTime = timings[timingIndex].startTime
            resolvedTimingIndex = timingIndex
            resolvedGlobalWordIndex = timings[timingIndex].globalWordIndex
            currentGlobalWordIndex = timings[timingIndex].globalWordIndex
        } else if let firstTiming = timings.first {
            resolvedTimingIndex = 0
            resolvedGlobalWordIndex = firstTiming.globalWordIndex
            currentGlobalWordIndex = firstTiming.globalWordIndex
        } else if let firstWord = allParagraphs[paragraphIndex].words.first {
            resolvedGlobalWordIndex = startFromWordGlobal > 0 ? startFromWordGlobal : firstWord.id
            currentGlobalWordIndex = resolvedGlobalWordIndex
        }

        lastPublishedHighlightTime = audioPlayer?.currentTime ?? 0
        audioPlayer?.play()
        isPlaying = true
        startSyncTimer()
    }

    private func mapCharacterTimingsToWords(
        alignment: ElevenLabsService.TTSAlignment?,
        words: [BookWord]
    ) -> [PlaybackHighlightTiming] {
        guard let alignment,
              !alignment.character_start_times_seconds.isEmpty else {
            return []
        }

        let charCount = alignment.character_start_times_seconds.count
        var timings: [PlaybackHighlightTiming] = []
        var charIndex = 0

        for word in words {
            let wordLength = word.text.count
            guard charIndex < charCount else { break }

            let startTime = alignment.character_start_times_seconds[charIndex]
            let endCharIndex = min(charIndex + wordLength - 1, charCount - 1)
            let endTime = alignment.character_end_times_seconds[
                min(endCharIndex, alignment.character_end_times_seconds.count - 1)
            ]

            timings.append(PlaybackHighlightTiming(
                globalWordIndex: word.id,
                startTime: startTime,
                endTime: endTime
            ))

            charIndex += wordLength + 1
            while charIndex < charCount && charIndex > 0 {
                let chars = alignment.characters
                if charIndex >= chars.count || chars[charIndex - 1] == " " { break }
                charIndex += 1
            }
        }

        return timings
    }

    private func startSyncTimer() {
        stopSyncTimer()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHighlight()
            }
        }
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func updateHighlight(force: Bool = false) {
        guard let player = audioPlayer else { return }
        guard !wordTimings.isEmpty else { return }

        let currentTime = player.currentTime
        guard let timingIndex = PlaybackHighlightHelper.timingIndex(
            for: currentTime,
            timings: wordTimings,
            previousIndex: resolvedTimingIndex
        ) else {
            return
        }

        resolvedTimingIndex = timingIndex
        let resolvedWordIndex = wordTimings[timingIndex].globalWordIndex
        resolvedGlobalWordIndex = resolvedWordIndex

        if force || PlaybackHighlightHelper.shouldPublishHighlight(
            resolvedWordIndex: resolvedWordIndex,
            displayedWordIndex: currentGlobalWordIndex,
            currentTime: currentTime,
            lastPublishedTime: lastPublishedHighlightTime,
            minimumInterval: minimumHighlightUpdateInterval,
            isLastWord: timingIndex == wordTimings.count - 1
        ) {
            currentGlobalWordIndex = resolvedWordIndex
            lastPublishedHighlightTime = currentTime
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
        var index = paragraphIndex

        while index < allParagraphs.count && allParagraphs[index].words.isEmpty {
            index += 1
        }

        guard index < allParagraphs.count else { return }
        let paragraph = allParagraphs[index]

        if audioCache[paragraph.id] != nil { return }

        let text = paragraph.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }

        do {
            let (audioData, timings) = try await generateAudio(
                text: text,
                words: paragraph.words,
                paragraphIndex: index
            )
            cacheAudio(audioData: audioData, timings: timings, paragraphId: paragraph.id)
            prefetchedAudio = audioData
            prefetchedTimings = timings
            prefetchedIndex = index
        } catch {
        }
    }

    private func generateAudio(
        text: String,
        words: [BookWord],
        paragraphIndex: Int
    ) async throws -> (Data, [PlaybackHighlightTiming]) {
        switch provider {
        case .elevenLabs:
            let response = try await ElevenLabsService.shared.generateSpeech(
                text: text,
                voiceId: voiceId,
                apiKey: apiKey,
                previousText: paragraphText(at: paragraphIndex - 1),
                nextText: paragraphText(at: paragraphIndex + 1)
            )
            let timings = mapCharacterTimingsToWords(
                alignment: response.normalized_alignment ?? response.alignment,
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
            return (audioData, estimateWordTimings(words: words, audioData: audioData))
        }
    }

    private func estimateWordTimings(
        words: [BookWord],
        audioData: Data
    ) -> [PlaybackHighlightTiming] {
        guard !words.isEmpty else { return [] }
        guard let tempPlayer = try? AVAudioPlayer(data: audioData) else { return [] }

        let duration = tempPlayer.duration
        let totalCharsWithSpaces = words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1)
        guard totalCharsWithSpaces > 0, duration > 0 else { return [] }

        let timePerChar = duration / Double(totalCharsWithSpaces)
        var timings: [PlaybackHighlightTiming] = []
        var currentTime = 0.0

        for (index, word) in words.enumerated() {
            let wordDuration = Double(word.text.count) * timePerChar
            timings.append(PlaybackHighlightTiming(
                globalWordIndex: word.id,
                startTime: currentTime,
                endTime: currentTime + wordDuration
            ))
            currentTime += wordDuration
            if index < words.count - 1 {
                currentTime += timePerChar
            }
        }

        return timings
    }

    private func saveCurrentPosition() {
        guard !allParagraphs.isEmpty else { return }
        guard currentParagraphArrayIndex < allParagraphs.count else { return }

        let paragraph = allParagraphs[currentParagraphArrayIndex]
        onPositionUpdate?(ReadingPosition(
            chapterIndex: paragraph.chapterIndex,
            paragraphIndex: currentParagraphArrayIndex,
            globalWordIndex: currentPlaybackWordIndex
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
