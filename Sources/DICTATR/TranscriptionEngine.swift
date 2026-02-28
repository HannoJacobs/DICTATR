import Foundation
import WhisperKit

@Observable
final class TranscriptionEngine {
    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var loadingProgress: String = ""

    private var whisperKit: WhisperKit?

    func loadModel(name: String = "large-v3-turbo") async throws {
        guard !isLoading else { return }

        await MainActor.run {
            isLoading = true
            loadingProgress = "Downloading model..."
        }

        let pipe = try await WhisperKit(
            WhisperKitConfig(model: name, verbose: false, logLevel: .error)
        )

        await MainActor.run {
            self.whisperKit = pipe
            self.isModelLoaded = true
            self.isLoading = false
            self.loadingProgress = ""
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
