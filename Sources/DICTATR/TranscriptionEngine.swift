import Foundation
import WhisperKit

@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0
    private(set) var loadingPhase: String = ""

    private var whisperKit: WhisperKit?

    func loadModel() async throws {
        guard !isLoading else { return }

        isLoading = true
        downloadProgress = 0
        loadingPhase = "Downloading model..."

        do {
            // Use WhisperKit's recommended model for this device
            let recommended = WhisperKit.recommendedModels()
            let variant = recommended.default

            // Step 1: Download model with progress tracking
            let modelFolder = try await WhisperKit.download(
                variant: variant,
                progressCallback: { [weak self] progress in
                    Task { @MainActor in
                        self?.downloadProgress = progress.fractionCompleted
                    }
                }
            )

            guard !Task.isCancelled else {
                self.isLoading = false
                self.loadingPhase = ""
                throw CancellationError()
            }

            // Step 2: Load the downloaded model into memory
            loadingPhase = "Loading model..."
            downloadProgress = 1.0

            let pipe = try await WhisperKit(
                WhisperKitConfig(
                    modelFolder: modelFolder.path,
                    verbose: true,
                    logLevel: .debug,
                    load: true,
                    download: false
                )
            )

            guard !Task.isCancelled else {
                self.isLoading = false
                self.loadingPhase = ""
                throw CancellationError()
            }

            self.whisperKit = pipe
            self.isModelLoaded = true
            self.isLoading = false
            self.loadingPhase = ""
        } catch {
            self.isLoading = false
            self.loadingPhase = ""
            self.downloadProgress = 0
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let pipe = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: "en",
            wordTimestamps: true
        )

        let results = try await pipe.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        let text = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded. Please wait for the model to finish loading."
        }
    }
}
