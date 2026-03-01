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
            statusSection

            Divider()

            if let text = appState.lastTranscription {
                lastTranscriptionSection(text: text)
                Divider()
            }

            actionsSection
        }
        .padding()
        .frame(width: 320)
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

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.menuBarIcon)
                .font(.title2)
                .foregroundStyle(appState.currentState == .recording ? .red : .primary)
                .symbolEffect(.pulse, isActive: appState.currentState == .recording)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)

                if appState.currentState == .recording {
                    Text(formatDuration(appState.audioRecorder.recordingDuration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(appState.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if appState.isModelLoading {
                ProgressView()
                    .controlSize(.small)
            }
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
            .opacity(appState.currentState == .transcribing || !appState.isModelLoaded ? 0.4 : 1)

            Divider()

            menuRow(
                PasteManager.checkAccessibilityPermission() ? "Accessibility: Granted" : "Grant Accessibility",
                icon: PasteManager.checkAccessibilityPermission() ? "checkmark.circle.fill" : "lock.shield"
            ) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .foregroundStyle(PasteManager.checkAccessibilityPermission() ? .green : .primary)

            menuRow("History...", icon: "clock") {
                openWindow(id: "history")
            }

            Divider()

            menuRow("Settings...", icon: "gear") {
                showingSettings = true
            }

            menuRow("Quit DICTATR", icon: "power") {
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    // MARK: - Menu Row (tap gesture, not Button)

    /// Full-width tappable menu row using onTapGesture instead of Button
    /// to avoid MenuBarExtra window dismissal issues with button styles.
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
            return "DICTATR"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing..."
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int(duration * 10) % 10
        if minutes > 0 {
            return String(format: "%d:%02d.%d", minutes, seconds, tenths)
        }
        return String(format: "%d.%d s", seconds, tenths)
    }
}
