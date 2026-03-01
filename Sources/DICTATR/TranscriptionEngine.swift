import Foundation
import WhisperKit

@Observable
@MainActor
final class TranscriptionEngine {
    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var loadingProgress: String = ""

    private var whisperKit: WhisperKit?

    func loadModel(name: String = "large-v3-turbo") async throws {
        guard !isLoading else { return }

        isLoading = true
        loadingProgress = "Downloading model..."

        do {
            let pipe = try await WhisperKit(
                WhisperKitConfig(model: name, verbose: false, logLevel: .error)
            )

            // Don't commit results if the task was cancelled during the await
            guard !Task.isCancelled else {
                self.isLoading = false
                self.loadingProgress = ""
                throw CancellationError()
            }

            self.whisperKit = pipe
            self.isModelLoaded = true
            self.isLoading = false
            self.loadingProgress = ""
        } catch {
            // Reset isLoading on failure so the user can retry.
            // Without this, the guard above permanently blocks all future attempts.
            self.isLoading = false
            self.loadingProgress = ""
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
