import SwiftUI

struct ModelDownloadView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("DICTATR")
                .font(.title2)
                .bold()

            Divider()

            VStack(spacing: 12) {
                if let error = appState.errorMessage {
                    // Error state with retry
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)

                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Retry Download") {
                        appState.errorMessage = nil
                        appState.startModelDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else if appState.transcriptionEngine.isLoading {
                    // Download/loading in progress
                    if usesIndeterminateProgress {
                        ProgressView {
                            Text(appState.transcriptionEngine.loadingPhase)
                                .font(.subheadline)
                        }
                    } else {
                        ProgressView(value: appState.transcriptionEngine.downloadProgress) {
                            Text(appState.transcriptionEngine.loadingPhase)
                                .font(.subheadline)
                        } currentValueLabel: {
                            Text(progressText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Text(loadingDetailText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    // Not started yet — kick it off
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(28)
        .frame(width: 320, height: 340)
        .onAppear {
            if !appState.transcriptionEngine.isLoading && !appState.transcriptionEngine.isModelLoaded {
                appState.startModelDownload()
            }
        }
    }

    private var progressText: String {
        let pct = Int(appState.transcriptionEngine.downloadProgress * 100)
        if pct <= 0 {
            return "Starting..."
        }
        return "\(pct)%"
    }

    private var usesIndeterminateProgress: Bool {
        switch appState.transcriptionEngine.loadingPhase {
        case "Selecting model...", "Checking model files...", "Using cached model files...", "Compiling on-device model...":
            return true
        default:
            return false
        }
    }

    private var loadingDetailText: String {
        if !appState.transcriptionEngine.loadingDetail.isEmpty {
            return appState.transcriptionEngine.loadingDetail
        }

        return "The first load after an install, update, or cache reset can take several minutes."
    }
}
