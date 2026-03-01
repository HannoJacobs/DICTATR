// ⚠️  DISTRIBUTION GOTCHA — Bundle.module crash
// Any SPM package view that calls Bundle.module internally (e.g. KeyboardShortcuts.Recorder,
// LaunchAtLogin.Toggle) crashes with EXC_BREAKPOINT/SIGTRAP when the app is distributed as a
// manually-bundled .app via create-dmg.sh. Xcode copies SPM resource bundles into
// Contents/Resources/ automatically; the shell-script bundler does NOT.
//
// Rule: only use APIs from these packages that do not render localised UI views:
//   SAFE:   KeyboardShortcuts.getShortcut(for:), KeyboardShortcuts.onKeyUp(for:)
//   UNSAFE: KeyboardShortcuts.Recorder   ← was here, caused Settings crash
//   UNSAFE: LaunchAtLogin.Toggle         ← was here, also removed
//
// Full post-mortem and diagnosis instructions: see settings-bug.md

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
                // Displaying the shortcut as text instead of KeyboardShortcuts.Recorder,
                // because Recorder calls Bundle.module and crashes in the DMG-bundled app.
                // To make this editable again, the app needs to be code-signed so Xcode can
                // copy the KeyboardShortcuts SPM resource bundle into Contents/Resources/.
                HStack {
                    Text("Toggle Dictation:")
                    Spacer()
                    Text(currentShortcutLabel)
                        .foregroundStyle(.secondary)
                }
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
        }
        .formStyle(.grouped)
        .padding()
    }

    private var currentShortcutLabel: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) {
            return "\(shortcut)"
        }
        return "F5 (default)"
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
