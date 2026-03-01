// TranscriptionEngine.swift
//
// Wraps WhisperKit for on-device speech-to-text. Runs entirely locally — no network calls
// during transcription. Model files are cached after first download.
//
// MODEL LOADING (two phases):
//   Phase 1 — WhisperKit.download(variant:progressCallback:)
//     Downloads model weights from HuggingFace Hub to the system cache.
//     If already cached, completes instantly (milliseconds, no network).
//     Uses recommendedModels().default — auto-selects the right size for this device.
//     DO NOT hardcode a variant like "openai_whisper-large-v3_turbo"; it ignores hardware
//     capabilities and may download a model that's too large/slow for the machine.
//
//   Phase 2 — WhisperKit(WhisperKitConfig(modelFolder:, load: true, download: false))
//     Loads the cached weights into Core ML / Apple Neural Engine memory.
//     `download: false` prevents WhisperKit from trying to re-download.
//
// MEMORY NOTE:
//   The model (~500MB–1.5GB depending on variant) is loaded onto Apple's Neural Engine,
//   which uses unified memory NOT attributed to the process in Activity Monitor. The app
//   may show only ~95MB RSS while the full model is loaded. This is normal. Nothing is
//   sent to the cloud — WhisperKit is 100% on-device.
//
// OBSERVABLE PROPERTIES (used by ModelDownloadView for progress UI):
//   downloadProgress: 0.0–1.0 during phase 1, then 1.0 during phase 2
//   loadingPhase: "Downloading model..." / "Loading model..." / "" (done)
//   isLoading: true while either phase is in progress
//   isModelLoaded: true once the pipeline is fully ready to transcribe

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
