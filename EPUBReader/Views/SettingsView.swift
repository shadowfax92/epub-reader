import SwiftUI

/// Settings hub: drills into the AI/TTS page and the reading-preferences page.
/// Presented as a sheet inside a `NavigationStack` (see LibraryView/ReaderView/PDFReaderView),
/// so the rows push and the trailing Done dismisses the sheet from this root.
struct SettingsView: View {
    @EnvironmentObject var bookStore: BookStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AIVoiceSettingsView()
                } label: {
                    settingsRow(
                        title: "AI Voice",
                        systemImage: "waveform",
                        tint: .indigo,
                        detail: bookStore.ttsProvider.displayName
                    )
                }

                NavigationLink {
                    ReadingSettingsView()
                } label: {
                    settingsRow(
                        title: "Reading",
                        systemImage: "textformat.size",
                        tint: .orange,
                        detail: bookStore.readerTheme.label
                    )
                }

                NavigationLink {
                    CloudSyncSettingsView()
                } label: {
                    settingsRow(
                        title: "Cloud Sync",
                        systemImage: "icloud.fill",
                        tint: .blue,
                        detail: bookStore.isCloudAvailable ? "iCloud" : "Off"
                    )
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
    }

    @ViewBuilder
    private func settingsRow(title: String, systemImage: String, tint: Color, detail: String) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}
