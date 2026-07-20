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
        .frame(width: 400, height: 420)
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
                Picker("Model", selection: selectedModelBinding) {
                    ForEach(WhisperModelChoice.allCases, id: \.self) { choice in
                        Text(choice.pickerLabel).tag(choice)
                    }
                }
                .disabled(!appState.canEditModelSelection)

                Text(appState.selectedModelChoice.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let blocked = appState.modelSwitchAvailabilityMessage {
                    Text(blocked)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text("Selected:")
                    Spacer()
                    Text(appState.selectedModelChoice.rawValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("Active:")
                    Spacer()
                    Text(appState.activeModelVariant ?? "Not loaded")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if appState.isModelLoading || appState.isModelSwitching {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(modelProgressTitle)
                            .font(.caption)
                        if !appState.transcriptionEngine.loadingDetail.isEmpty {
                            Text(appState.transcriptionEngine.loadingDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if appState.transcriptionEngine.loadingPhase == "Downloading model..." {
                            ProgressView(value: appState.transcriptionEngine.downloadProgress)
                        } else {
                            ProgressView()
                        }
                    }
                }

                if let error = appState.errorMessage,
                   !appState.isModelLoading,
                   !appState.isModelSwitching,
                   !appState.isModelLoaded {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry Model Load") {
                        appState.retryModelLoad()
                    }
                }

                Text(appState.configuredModelPolicySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Input Microphone") {
                Text(appState.resolvedInputDevice?.localizedName ?? "No microphone available")
                    .font(.body)

                Text(inputResolutionCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.inputDevicePrecedence.isEmpty {
                    Text("No pinned mics yet. Use Pin Mic in the menu, or dictate once to start a history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(appState.inputDevicePrecedence.enumerated()), id: \.element.uid) { index, preference in
                        precedenceRow(index: index, preference: preference)
                    }
                }

                Button("Refresh Devices") {
                    appState.refreshInputDeviceInventory(source: "settings")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            appState.refreshInputDeviceInventory(source: "settingsAppear")
        }
    }

    private var inputResolutionCaption: String {
        switch appState.resolvedInputSource {
        case .preferenceMatch:
            return "DICTATR will capture from the highest-precedence mic that is currently connected."
        case .systemDefault:
            return "No pinned mic is available, so DICTATR is falling back to the macOS default input."
        case .firstAvailable:
            return "No pinned or default mic matched, so DICTATR is using the first available capture device."
        case nil:
            return "Connect a microphone to begin."
        }
    }

    private func precedenceRow(index: Int, preference: InputDevicePreference) -> some View {
        let isLast = index == appState.inputDevicePrecedence.count - 1
        return HStack {
            Text("\(index + 1). \(preference.name)")
                .lineLimit(1)
            Spacer()
            Button("Pin") {
                appState.pinInputDevice(preference)
            }
            .disabled(index == 0)
            Button("Up") {
                appState.moveInputDeviceUp(uid: preference.uid)
            }
            .disabled(index == 0)
            Button("Down") {
                appState.moveInputDeviceDown(uid: preference.uid)
            }
            .disabled(isLast)
            Button("Remove") {
                appState.removeInputDevice(uid: preference.uid)
            }
        }
    }

    private var selectedModelBinding: Binding<WhisperModelChoice> {
        Binding(
            get: { appState.selectedModelChoice },
            set: { appState.applyModelSelection($0) }
        )
    }

    private var modelProgressTitle: String {
        if appState.isModelSwitching && !appState.isModelLoading {
            return "Unloading active model..."
        }
        return appState.transcriptionEngine.loadingPhase.isEmpty
            ? "Loading model..."
            : appState.transcriptionEngine.loadingPhase
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
