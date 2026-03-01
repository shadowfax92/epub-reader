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

    private var apiKey: String = ""
    private var voiceId: String = ""
    var speed: Double = 1.0 {
        didSet { audioPlayer?.rate = Float(speed) }
    }

    private var onPositionUpdate: ((ReadingPosition) -> Void)?

    struct WordTiming {
        let globalWordIndex: Int
        let startTime: Double
        let endTime: Double
    }

    func configure(apiKey: String, voiceId: String, speed: Double, onPositionUpdate: @escaping (ReadingPosition) -> Void) {
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.speed = speed
        self.onPositionUpdate = onPositionUpdate
        configureAudioSession()
    }

    func setBook(paragraphs: [BookParagraph]) {
        self.allParagraphs = paragraphs
    }

    func play(fromParagraphIndex index: Int, wordIndex: Int = 0) {
        currentParagraphArrayIndex = index
        Task { await generateAndPlay(paragraphIndex: index, startFromWordGlobal: wordIndex) }
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
        guard audioPlayer != nil else {
            play(fromParagraphIndex: currentParagraphArrayIndex)
            return
        }
        audioPlayer?.play()
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
            print("Audio session configuration error: \(error)")
        }
    }

    private func generateAndPlay(paragraphIndex: Int, startFromWordGlobal: Int = 0) async {
        guard paragraphIndex < allParagraphs.count else {
            isPlaying = false
            return
        }

        guard !apiKey.isEmpty, !voiceId.isEmpty else {
            error = "Please set your API key and voice in Settings."
            return
        }

        isLoadingAudio = true
        error = nil

        let paragraph = allParagraphs[paragraphIndex]
        let text = paragraph.words.map(\.text).joined(separator: " ")

        guard !text.isEmpty else {
            currentParagraphArrayIndex = paragraphIndex + 1
            await generateAndPlay(paragraphIndex: paragraphIndex + 1, startFromWordGlobal: startFromWordGlobal)
            return
        }

        do {
            let response = try await ElevenLabsService.shared.generateSpeech(
                text: text,
                voiceId: voiceId,
                apiKey: apiKey
            )

            let timings = mapCharacterTimingsToWords(
                alignment: response.alignment,
                words: paragraph.words
            )

            guard let audioData = Data(base64Encoded: response.audio_base64) else {
                throw ElevenLabsError.invalidResponse
            }

            try startPlayback(
                audioData: audioData,
                timings: timings,
                paragraphIndex: paragraphIndex,
                paragraphId: paragraph.id,
                startFromWordGlobal: startFromWordGlobal
            )

            isLoadingAudio = false

            prefetchTask?.cancel()
            prefetchTask = Task { await prefetchNext(paragraphIndex: paragraphIndex + 1) }

        } catch {
            isLoadingAudio = false
            self.error = error.localizedDescription
        }
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

        audioPlayer?.play()
        isPlaying = true
        startSyncTimer()
    }

    private func mapCharacterTimingsToWords(alignment: ElevenLabsService.TTSAlignment?, words: [BookWord]) -> [WordTiming] {
        guard let alignment = alignment,
              !alignment.character_start_times_seconds.isEmpty else {
            // Fallback: evenly distribute timings if no alignment data
            return []
        }

        let charCount = alignment.character_start_times_seconds.count
        var timings: [WordTiming] = []
        var charIndex = 0

        for word in words {
            let wordLength = word.text.count
            guard charIndex < charCount else { break }

            let startTime = alignment.character_start_times_seconds[charIndex]
            let endCharIndex = min(charIndex + wordLength - 1, charCount - 1)
            let endTime = alignment.character_end_times_seconds[min(endCharIndex, alignment.character_end_times_seconds.count - 1)]

            timings.append(WordTiming(
                globalWordIndex: word.id,
                startTime: startTime,
                endTime: endTime
            ))

            // Advance past word chars + space separator
            charIndex += wordLength + 1
            // Safety: if we overshot due to alignment differences, find the next space
            while charIndex < charCount && charIndex > 0 {
                let chars = alignment.characters
                if charIndex >= chars.count { break }
                if chars[charIndex - 1] == " " { break }
                charIndex += 1
            }
        }

        return timings
    }

    private func startSyncTimer() {
        stopSyncTimer()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHighlight()
            }
        }
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func updateHighlight() {
        guard let player = audioPlayer, player.isPlaying else { return }
        let currentTime = player.currentTime

        if let timing = wordTimings.last(where: { $0.startTime <= currentTime }) {
            if timing.globalWordIndex != currentGlobalWordIndex {
                currentGlobalWordIndex = timing.globalWordIndex
            }
        }
    }

    private func advanceToNext() {
        stopSyncTimer()
        let nextIndex = currentParagraphArrayIndex + 1

        guard nextIndex < allParagraphs.count else {
            isPlaying = false
            saveCurrentPosition()
            return
        }

        if let cachedAudio = prefetchedAudio,
           let cachedTimings = prefetchedTimings,
           prefetchedIndex == nextIndex {
            let paragraph = allParagraphs[nextIndex]
            do {
                try startPlayback(
                    audioData: cachedAudio,
                    timings: cachedTimings,
                    paragraphIndex: nextIndex,
                    paragraphId: paragraph.id,
                    startFromWordGlobal: 0
                )
                prefetchedAudio = nil
                prefetchedTimings = nil
                prefetchTask?.cancel()
                prefetchTask = Task { await prefetchNext(paragraphIndex: nextIndex + 1) }
            } catch {
                self.error = "Playback error: \(error.localizedDescription)"
            }
        } else {
            Task { await generateAndPlay(paragraphIndex: nextIndex) }
        }
    }

    private func prefetchNext(paragraphIndex: Int) async {
        guard paragraphIndex < allParagraphs.count else { return }

        let paragraph = allParagraphs[paragraphIndex]
        let text = paragraph.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }

        do {
            let response = try await ElevenLabsService.shared.generateSpeech(
                text: text,
                voiceId: voiceId,
                apiKey: apiKey
            )

            let timings = mapCharacterTimingsToWords(
                alignment: response.alignment,
                words: paragraph.words
            )

            guard let audioData = Data(base64Encoded: response.audio_base64) else { return }

            prefetchedAudio = audioData
            prefetchedTimings = timings
            prefetchedIndex = paragraphIndex
        } catch {
            // Prefetch failure is non-critical
        }
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
            if flag {
                self.advanceToNext()
            }
        }
    }
}
