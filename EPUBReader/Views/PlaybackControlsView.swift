import SwiftUI

/// Shared playback cluster (loading/error, speed pills, transport row, progress) used by both
/// the EPUB and PDF readers. Reader-specific rows slot in via the two accessory builders:
/// `topAccessory` renders above the speed pills, `actionAccessory` between pills and transport.
struct PlaybackControlsView<TopAccessory: View, ActionAccessory: View>: View {
    @ObservedObject var playbackManager: AudioPlaybackManager
    @Binding var currentSpeed: Double
    let progressPercent: Int?
    let onSpeedChange: (Double) -> Void
    let onPlayPause: () -> Void
    private let topAccessory: TopAccessory
    private let actionAccessory: ActionAccessory

    private static var speedOptions: [Double] {
        [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 2.5]
    }

    init(
        playbackManager: AudioPlaybackManager,
        currentSpeed: Binding<Double>,
        progressPercent: Int?,
        onSpeedChange: @escaping (Double) -> Void,
        onPlayPause: @escaping () -> Void,
        @ViewBuilder topAccessory: () -> TopAccessory,
        @ViewBuilder actionAccessory: () -> ActionAccessory
    ) {
        self.playbackManager = playbackManager
        self._currentSpeed = currentSpeed
        self.progressPercent = progressPercent
        self.onSpeedChange = onSpeedChange
        self.onPlayPause = onPlayPause
        self.topAccessory = topAccessory()
        self.actionAccessory = actionAccessory()
    }

    var body: some View {
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

            topAccessory

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.speedOptions, id: \.self) { speed in
                        Button {
                            currentSpeed = speed
                            playbackManager.speed = speed
                            onSpeedChange(speed)
                        } label: {
                            Text(Self.formatSpeed(speed))
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

            actionAccessory

            HStack(spacing: 36) {
                Button { playbackManager.skip(seconds: -10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                        .foregroundStyle(.primary)
                        .frame(width: 48, height: 48)
                }

                Button { onPlayPause() } label: {
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

            if let progress = progressPercent {
                Text("\(progress)%")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func formatSpeed(_ speed: Double) -> String {
        if speed == Double(Int(speed)) {
            return "\(Int(speed)).0x"
        }
        return String(format: "%.2gx", speed)
    }
}
