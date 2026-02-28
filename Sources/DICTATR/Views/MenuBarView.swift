import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            statusSection

            Divider()

            // Last transcription
            if let text = appState.lastTranscription {
                lastTranscriptionSection(text: text)
                Divider()
            }

            // Actions
            actionsSection
        }
        .padding()
        .frame(width: 320)
    }

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

    @ViewBuilder
    private var actionsSection: some View {
        VStack(spacing: 4) {
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

            Button {
                appState.toggleRecording()
            } label: {
                Label(
                    appState.currentState == .recording ? "Stop Recording" : "Start Dictation",
                    systemImage: appState.currentState == .recording ? "stop.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .disabled(appState.currentState == .transcribing || !appState.isModelLoaded)

            Divider()

            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(
                    PasteManager.checkAccessibilityPermission() ? "Accessibility: Granted" : "Grant Accessibility",
                    systemImage: PasteManager.checkAccessibilityPermission() ? "checkmark.circle.fill" : "lock.shield"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(PasteManager.checkAccessibilityPermission() ? .green : .orange)

            Divider()

            SettingsLink {
                Label("Settings...", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit DICTATR", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
    }

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
