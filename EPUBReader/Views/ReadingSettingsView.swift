import SwiftUI

/// Non-AI reading preferences: appearance (theme, font size) and narration behavior.
/// Pushed from `SettingsView`.
struct ReadingSettingsView: View {
    @EnvironmentObject var bookStore: BookStore

    var body: some View {
        Form {
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
            }

            Section("Narration") {
                Toggle("Auto-Advance Pages", isOn: autoAdvancePagesBinding)
            }
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Bindings

    private var themeBinding: Binding<ReaderTheme> {
        Binding(get: { bookStore.readerTheme }, set: { bookStore.readerTheme = $0 })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { bookStore.fontSize }, set: { bookStore.fontSize = $0 })
    }

    private var autoAdvancePagesBinding: Binding<Bool> {
        Binding(
            get: { bookStore.autoAdvancePagesWithSpeech },
            set: { bookStore.autoAdvancePagesWithSpeech = $0 }
        )
    }
}
