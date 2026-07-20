// MenuBarView.swift
//
// The primary popup shown when the user clicks the DICTATR menu bar icon.
// Handles two panels — the main menu and an inline settings panel — via local @State.
//
// BUTTON STYLE NOTES — why onTapGesture instead of Button:
//   .borderless buttons: tiny hit target (just the label text/icon, not the full row)
//   .plain buttons: can dismiss the MenuBarExtra window before the action fires
//   Solution: HStack rows + .contentShape(Rectangle()) + .onTapGesture gives a
//   reliable full-width hit target that fires correctly inside MenuBarExtra(.window).
//
// SETTINGS NAVIGATION — why @State is local, not @Binding from DICTATRApp:
//   If showingSettings lived on DICTATRApp and changed which view the MenuBarExtra shows,
//   SwiftUI would tear down and reconstruct the view hierarchy (potentially closing the
//   window). Keeping it local means the same MenuBarView instance swaps between panels
//   with no window teardown. See settings-bug.md for the full history.

import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var showingSettings = false

    var body: some View {
        if showingSettings {
            settingsPanel
        } else {
            mainPanel
        }
    }

    // MARK: - Main Panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            headlineSection

            Divider()

            inputDeviceSection

            Divider()

            statusSection

            Divider()

            if let text = appState.lastTranscription {
                lastTranscriptionSection(text: text)
                Divider()
            }

            actionsSection
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            appState.refreshInputDeviceInventory(source: "menuAppear")
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingSettings = false
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            GeneralSettingsView()
                .environment(appState)
        }
        .frame(width: 360)
    }

    // MARK: - Headline

    @ViewBuilder
    private var headlineSection: some View {
        VStack(spacing: 4) {
            Text("DICTATR")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)

            Text(statusTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Input Device

    @ViewBuilder
    private var inputDeviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(appState.currentState == .recording ? .red : .primary)
                    .symbolEffect(.pulse, isActive: appState.currentState == .recording)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Input Mic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(resolvedMicLabel)
                        .font(.headline)
                        .lineLimit(2)
                }

                Spacer()

                if appState.isModelLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let sourceLabel = resolvedSourceLabel {
                Text(sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !appState.availableInputDevices.isEmpty {
                Menu {
                    ForEach(appState.availableInputDevices, id: \.uniqueID) { candidate in
                        Button {
                            appState.pinAvailableInputDevice(candidate)
                        } label: {
                            if candidate.uniqueID == appState.resolvedInputDevice?.uniqueID {
                                Label(candidate.localizedName, systemImage: "pin.fill")
                            } else {
                                Text(candidate.localizedName)
                            }
                        }
                    }
                } label: {
                    Label("Pin Mic…", systemImage: "pin")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
            }

            if !appState.inputDevicePrecedence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Precedence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(Array(appState.inputDevicePrecedence.enumerated()), id: \.element.uid) { index, preference in
                        precedenceRow(index: index, preference: preference)
                    }
                }
            }
        }
    }

    private func precedenceRow(index: Int, preference: InputDevicePreference) -> some View {
        let isOnline = availableUIDs.contains(preference.uid)
        let isLast = index == appState.inputDevicePrecedence.count - 1

        return HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            Text(preference.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isOnline ? .primary : .secondary)

            if !isOnline {
                Text("offline")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                appState.pinInputDevice(preference)
            } label: {
                Image(systemName: index == 0 ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help("Pin as top precedence")

            Button {
                appState.moveInputDeviceUp(uid: preference.uid)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                appState.moveInputDeviceDown(uid: preference.uid)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(isLast)

            Button {
                appState.removeInputDevice(uid: preference.uid)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove from precedence history")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.menuBarIcon)
                .font(.title2)
                .foregroundStyle(appState.currentState == .recording ? .red : .primary)
                .symbolEffect(.pulse, isActive: appState.currentState == .recording)

            VStack(alignment: .leading, spacing: 2) {
                if appState.currentState == .recording {
                    let duration = appState.audioRecorder.recordingDuration
                    let progress = min(duration / 300.0, 1.0)
                    let color = recordingWarningColor(progress: progress)
                    Text("\(formatRecordingTime(duration)) / 5:00")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(color)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color)
                                .frame(width: geo.size.width * progress)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                } else {
                    Text(appState.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Last Transcription

    @ViewBuilder
    private func lastTranscriptionSection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last Dictation")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.body)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                appState.copyToClipboard(text)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: 2) {
            if let error = appState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if appState.currentState == .idle, !appState.isModelLoading, !appState.isModelLoaded {
                        Button("Retry Model Load") {
                            appState.retryModelLoad()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }

            menuRow(
                appState.currentState == .recording ? "Stop Recording" : "Start Dictation",
                icon: appState.currentState == .recording ? "stop.fill" : "mic.fill"
            ) {
                appState.toggleRecording()
            }
            .opacity(appState.currentState == .recording || appState.canStartDictationFromMenu ? 1 : 0.4)
            .allowsHitTesting(appState.currentState == .recording || appState.canStartDictationFromMenu)

            Divider()

            menuRow(
                microphoneStatusTitle,
                icon: microphoneStatusIcon
            ) {
                Task { @MainActor in
                    await appState.handleMicrophonePermissionAction(source: "menu")
                }
            }
            .foregroundStyle(microphoneStatusColor)

            menuRow(
                PasteManager.checkAccessibilityPermission() ? "Accessibility: Granted" : "Grant Accessibility",
                icon: PasteManager.checkAccessibilityPermission() ? "checkmark.circle.fill" : "lock.shield"
            ) {
                PasteManager.openAccessibilitySettings()
            }
            .foregroundStyle(PasteManager.checkAccessibilityPermission() ? .green : .primary)

            menuRow("History...", icon: "clock") {
                openWindow(id: "history")
            }

            Divider()

            menuRow("Settings...", icon: "gear") {
                showingSettings = true
            }

            // DispatchQueue.main.async ensures the tap gesture completes before the
            // process exits — avoids any chance of terminate firing mid-event-handling.
            menuRow("Quit DICTATR", icon: "power") {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Menu Row

    /// Full-width tappable row. Uses onTapGesture instead of Button to avoid
    /// MenuBarExtra window-dismissal issues inherent in SwiftUI button styles.
    private func menuRow(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
            Text(title)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }

    // MARK: - Helpers

    private var statusTitle: String {
        switch appState.currentState {
        case .idle:
            return "Ready"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing..."
        }
    }

    private var resolvedMicLabel: String {
        appState.resolvedInputDevice?.localizedName ?? "No microphone available"
    }

    private var resolvedSourceLabel: String? {
        switch appState.resolvedInputSource {
        case .preferenceMatch:
            return "Using top available pinned mic"
        case .systemDefault:
            return "Fallback: macOS default input"
        case .firstAvailable:
            return "Fallback: first available mic"
        case nil:
            return nil
        }
    }

    private var availableUIDs: Set<String> {
        Set(appState.availableInputDevices.map(\.uniqueID))
    }

    private func formatRecordingTime(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func recordingWarningColor(progress: Double) -> Color {
        if progress < 0.6 { return .green }
        if progress < 0.8 { return .orange }
        return .red
    }

    private var microphoneStatusTitle: String {
        switch appState.microphonePermissionStatus {
        case .authorized:
            return "Microphone: Granted"
        case .restricted:
            return "Microphone: Restricted"
        case .notDetermined, .denied:
            return "Grant Microphone"
        }
    }

    private var microphoneStatusIcon: String {
        switch appState.microphonePermissionStatus {
        case .authorized:
            return "checkmark.circle.fill"
        case .restricted:
            return "exclamationmark.shield"
        case .notDetermined, .denied:
            return "mic.badge.plus"
        }
    }

    private var microphoneStatusColor: Color {
        switch appState.microphonePermissionStatus {
        case .authorized:
            return .green
        case .restricted:
            return .orange
        case .notDetermined, .denied:
            return .primary
        }
    }
}
