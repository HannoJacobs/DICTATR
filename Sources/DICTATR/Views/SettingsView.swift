import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environment(appState)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 400, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle Dictation:", name: .toggleDictation)
            }

            Section("Transcription") {
                Picker("Model", selection: .constant("large-v3-turbo")) {
                    Text("large-v3-turbo").tag("large-v3-turbo")
                }
                .disabled(true)
                .help("Model selection will be available in a future update")
            }

            Section("Behavior") {
                Toggle("Auto-paste after transcription", isOn: $state.autoPasteEnabled)

                Stepper(
                    "Keep last \(appState.retentionCount) dictations",
                    value: $state.retentionCount,
                    in: 10...1000,
                    step: 10
                )
            }

            Section("System") {
                Text("Launch at login requires a signed app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("DICTATR")
                .font(.title)
                .bold()

            Text("Local speech-to-text dictation")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Powered by WhisperKit")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
