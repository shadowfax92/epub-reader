import SwiftUI
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var bookStore: BookStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput: String = ""
    @State private var voices: [ElevenLabsService.Voice] = []
    @State private var isLoadingVoices = false
    @State private var voiceError: String?
    @State private var showApiKey = false
    @State private var previewingVoiceId: String?
    @State private var previewPlayer: AVPlayer?
    @State private var previewEndObserver: (any NSObjectProtocol)?

    var body: some View {
        Form {
            Section {
                HStack {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textContentType(.password)
                    }
                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: apiKeyInput) { _, newValue in
                    bookStore.apiKey = newValue
                }

                Button {
                    Task { await loadVoices() }
                } label: {
                    HStack {
                        Text("Load Voices")
                        Spacer()
                        if isLoadingVoices {
                            ProgressView()
                        }
                    }
                }
                .disabled(apiKeyInput.isEmpty || isLoadingVoices)

            } header: {
                Text("ElevenLabs")
            } footer: {
                Text("Enter your ElevenLabs API key to enable text-to-speech.")
            }

            if !voices.isEmpty {
                Section("Voice") {
                    ForEach(voices, id: \.voice_id) { voice in
                        HStack {
                            Button {
                                bookStore.selectedVoiceId = voice.voice_id
                                bookStore.selectedVoiceName = voice.name
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(voice.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    if !voice.subtitle.isEmpty {
                                        Text(voice.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if let url = voice.preview_url, let audioURL = URL(string: url) {
                                Button {
                                    togglePreview(voiceId: voice.voice_id, url: audioURL)
                                } label: {
                                    Image(systemName: previewingVoiceId == voice.voice_id ? "stop.circle.fill" : "play.circle")
                                        .font(.title3)
                                        .foregroundStyle(previewingVoiceId == voice.voice_id ? .red : .accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                            if bookStore.selectedVoiceId == voice.voice_id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            } else if !bookStore.selectedVoiceName.isEmpty {
                Section("Voice") {
                    HStack {
                        Text("Selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(bookStore.selectedVoiceName)
                    }
                }
            }

            if let voiceError {
                Section {
                    Text(voiceError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("Appearance") {
                HStack {
                    Text("Theme")
                    Spacer()
                    Picker("", selection: themeBinding) {
                        ForEach(ReaderTheme.allCases, id: \.rawValue) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(bookStore.fontSize))pt")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: fontSizeBinding,
                    in: 12...32,
                    step: 1
                )

                HStack {
                    Text("Reading Mode")
                    Spacer()
                    Picker("", selection: pagedModeBinding) {
                        Text("Scroll").tag(false)
                        Text("Paged").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            apiKeyInput = bookStore.apiKey
            if !bookStore.apiKey.isEmpty && voices.isEmpty {
                Task { await loadVoices() }
            }
        }
        .onDisappear {
            stopPreview()
        }
    }

    private var themeBinding: Binding<ReaderTheme> {
        Binding(get: { bookStore.readerTheme }, set: { bookStore.readerTheme = $0 })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { bookStore.fontSize }, set: { bookStore.fontSize = $0 })
    }

    private var pagedModeBinding: Binding<Bool> {
        Binding(get: { bookStore.isPagedMode }, set: { bookStore.isPagedMode = $0 })
    }

    private func loadVoices() async {
        isLoadingVoices = true
        voiceError = nil

        do {
            voices = try await ElevenLabsService.shared.fetchVoices(apiKey: apiKeyInput)
        } catch {
            voiceError = error.localizedDescription
        }

        isLoadingVoices = false
    }

    private func togglePreview(voiceId: String, url: URL) {
        if previewingVoiceId == voiceId {
            stopPreview()
            return
        }
        stopPreview()
        let player = AVPlayer(url: url)
        previewPlayer = player
        previewingVoiceId = voiceId

        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor [self] in
                previewingVoiceId = nil
                previewPlayer = nil
                previewEndObserver = nil
            }
        }
        player.play()
    }

    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewingVoiceId = nil
        if let observer = previewEndObserver {
            NotificationCenter.default.removeObserver(observer)
            previewEndObserver = nil
        }
    }
}
