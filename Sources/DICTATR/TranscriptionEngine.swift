// TranscriptionEngine.swift
//
// Wraps WhisperKit for on-device speech-to-text. Runs entirely locally — no network calls
// during transcription. Model files are cached after first download.
//
// MODEL LOADING (two phases):
//   Phase 1 — WhisperKit.download(variant:progressCallback:)
//     Downloads model weights from HuggingFace Hub to the system cache.
//     If already cached, completes instantly (milliseconds, no network).
//     Starts from WhisperKit's recommended model table, but DICTATR can override the
//     default when a "supported" model is still operationally too slow for this app.
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
// OBSERVABLE PROPERTIES (used by the menu status UI for progress state):
//   downloadProgress: 0.0–1.0 during phase 1, then 1.0 during phase 2
//   loadingPhase: "Downloading model..." / "Loading model..." / "" (done)
//   isLoading: true while either phase is in progress
//   isModelLoaded: true once the pipeline is fully ready to transcribe

import Darwin
import Foundation
import WhisperKit

@Observable
@MainActor
final class TranscriptionEngine {
    struct TranscriptionOutput: Sendable {
        let rawText: String
        let text: String
        let containsOnlyPlaceholderTokens: Bool
    }

    private struct ModelSelection {
        let variant: String
        let whisperKitDefault: String
        let reason: String
    }

    private struct ModelLoadRecoveryState: Codable {
        let variant: String
        let stage: String
        let launchSessionID: String
        let startedAt: Date
        let updatedAt: Date
        let osBuild: String
        let compiledCacheExistedAtStart: Bool
    }

    private enum ModelLoadStage {
        static let selecting = "selecting"
        static let checkingModelFiles = "checking-model-files"
        static let usingCachedModelFiles = "using-cached-model-files"
        static let compiling = "compiling"
    }

    private static let compileWarningThreshold: TimeInterval = 90
    private static let slowStartupDefaultVariant = "openai_whisper-large-v3-v20240930_626MB"
    private static let reliabilityFallbackVariant = "openai_whisper-small.en"

    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0
    private(set) var loadingPhase: String = ""
    private(set) var loadingDetail: String = ""
    private(set) var configuredModelVariant = "Selecting model..."
    private(set) var configuredModelPolicySummary = "Waiting for WhisperKit model selection."

    private var whisperKit: WhisperKit?
    private var loadHeartbeatTask: Task<Void, Never>?
    private var nextDownloadLogThreshold: Double = 0.1
    private var hasLoggedWarmCompileWarning = false

    func loadModel() async throws {
        guard !isLoading else {
            AppDiagnostics.warning(.transcriptionEngine, "loadModel ignored because a model load is already in progress phase=\(loadingPhase)")
            return
        }

        let loadStartedAt = Date()
        isLoading = true
        downloadProgress = 0
        loadingPhase = "Selecting model..."
        loadingDetail = "Inspecting device support and cached WhisperKit files."
        nextDownloadLogThreshold = 0.1

        do {
            let selection = Self.selectModel()
            let variant = selection.variant
            configuredModelVariant = variant
            configuredModelPolicySummary = Self.modelPolicySummary(for: selection)
            AppDiagnostics.info(
                .transcriptionEngine,
                "Model variant selected effectiveVariant=\(selection.variant) whisperKitDefault=\(selection.whisperKitDefault) reason=\(selection.reason)"
            )
            Self.recoverFromInterruptedCompileIfNeeded(for: variant)
            let compiledCacheExistedAtStart = Self.compiledCacheExists()
            Self.persistModelLoadRecoveryState(
                variant: variant,
                stage: ModelLoadStage.selecting,
                startedAt: loadStartedAt,
                compiledCacheExistedAtStart: compiledCacheExistedAtStart
            )
            startLoadHeartbeat(
                variant: variant,
                startedAt: loadStartedAt,
                compiledCacheExistedAtStart: compiledCacheExistedAtStart
            )
            defer { stopLoadHeartbeat() }

            AppDiagnostics.info(
                .transcriptionEngine,
                "Model load requested variant=\(variant) compiledCache=\(Self.compiledCacheSummary())"
            )

            // Step 1: Use the local cached model folder when it already exists.
            // Falling back to WhisperKit.download() forces remote model discovery even
            // when the files are on disk, which can make startup look hung.
            let modelFolder: URL
            if let cachedModelFolder = Self.cachedModelFolder(for: variant) {
                loadingPhase = "Using cached model files..."
                loadingDetail = "Using cached WhisperKit files for \(variant)."
                downloadProgress = 1.0
                Self.persistModelLoadRecoveryState(
                    variant: variant,
                    stage: ModelLoadStage.usingCachedModelFiles,
                    startedAt: loadStartedAt,
                    compiledCacheExistedAtStart: compiledCacheExistedAtStart
                )
                modelFolder = cachedModelFolder
                AppDiagnostics.info(
                    .transcriptionEngine,
                    "Using cached local model folder variant=\(variant) folder=\(modelFolder.path) remoteLookup=skipped compiledCache=\(Self.compiledCacheSummary())"
                )
            } else {
                let downloadStartedAt = Date()
                loadingPhase = "Checking model files..."
                loadingDetail = "Checking cached WhisperKit files for \(variant)."
                Self.persistModelLoadRecoveryState(
                    variant: variant,
                    stage: ModelLoadStage.checkingModelFiles,
                    startedAt: loadStartedAt,
                    compiledCacheExistedAtStart: compiledCacheExistedAtStart
                )
                modelFolder = try await WhisperKit.download(
                    variant: variant,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            self?.handleDownloadProgress(progress, variant: variant)
                        }
                    }
                )

                let downloadElapsed = Date().timeIntervalSince(downloadStartedAt)
                AppDiagnostics.info(
                    .transcriptionEngine,
                    "Model files ready variant=\(variant) folder=\(modelFolder.path) downloadElapsed=\(Self.durationString(downloadElapsed)) compiledCache=\(Self.compiledCacheSummary())"
                )
            }

            guard !Task.isCancelled else {
                resetLoadingState()
                throw CancellationError()
            }

            // Step 2: Load the downloaded model into memory
            let compileStartedAt = Date()
            loadingPhase = "Compiling on-device model..."
            loadingDetail = "Compiling \(variant) for Apple Neural Engine. After an install, update, or cache reset this can take several minutes."
            downloadProgress = 1.0
            Self.persistModelLoadRecoveryState(
                variant: variant,
                stage: ModelLoadStage.compiling,
                startedAt: loadStartedAt,
                compiledCacheExistedAtStart: compiledCacheExistedAtStart
            )
            AppDiagnostics.info(
                .transcriptionEngine,
                "CoreML load started variant=\(variant) folder=\(modelFolder.path) compiledCache=\(Self.compiledCacheSummary())"
            )

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
                resetLoadingState()
                throw CancellationError()
            }

            self.whisperKit = pipe
            self.isModelLoaded = true
            let compileElapsed = Date().timeIntervalSince(compileStartedAt)
            let totalElapsed = Date().timeIntervalSince(loadStartedAt)
            let completionMessage = "Model load completed variant=\(variant) folder=\(modelFolder.path) compileElapsed=\(Self.durationString(compileElapsed)) totalElapsed=\(Self.durationString(totalElapsed)) compiledCache=\(Self.compiledCacheSummary())"
            if totalElapsed >= 30 {
                AppDiagnostics.warning(.transcriptionEngine, completionMessage)
            } else {
                AppDiagnostics.info(.transcriptionEngine, completionMessage)
            }
            Self.clearModelLoadRecoveryState()
            resetLoadingState()
        } catch {
            let elapsed = Date().timeIntervalSince(loadStartedAt)
            AppDiagnostics.error(
                .transcriptionEngine,
                "Model load failed phase=\(loadingPhase) detail=\(loadingDetail) progress=\(Self.progressString(downloadProgress)) elapsed=\(Self.durationString(elapsed)) compiledCache=\(Self.compiledCacheSummary()) error=\(error.localizedDescription)"
            )
            Self.clearModelLoadRecoveryState()
            resetLoadingState()
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionOutput {
        guard let pipe = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let fileAttributes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)) ?? [:]
        let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
        let creationDate = (fileAttributes[.creationDate] as? Date)?.description ?? "unknown"
        AppDiagnostics.info(
            .transcriptionEngine,
            "transcribe requested file=\(audioURL.lastPathComponent) path=\(audioURL.path) size=\(fileSize)B createdAt=\(creationDate) modelLoaded=\(AppDiagnostics.boolLabel(isModelLoaded)) configuredVariant=\(configuredModelVariant) loadingPhase=\(loadingPhase) loadingDetail=\(loadingDetail)"
        )

        let options = DecodingOptions(
            language: "en",
            wordTimestamps: true
        )

        AppDiagnostics.info(
            .transcriptionEngine,
            "transcribe decode options language=en wordTimestamps=yes file=\(audioURL.lastPathComponent)"
        )

        let results = try await pipe.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        let segmentTexts = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let segmentSummaries = results.enumerated().map { index, result in
            "segment[\(index)] chars=\(result.text.count) text=\(Self.logQuoted(AppDiagnostics.compactText(result.text, limit: 300)))"
        }.joined(separator: " ")
        let text = segmentTexts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = Self.normalizeTranscription(text)
        let placeholderOnly = Self.containsOnlyPlaceholderTokens(in: text)

        AppDiagnostics.info(
            .transcriptionEngine,
            "transcribe raw segmentCount=\(results.count) rawText=\(Self.logQuoted(AppDiagnostics.compactText(text, limit: 1200))) normalizedText=\(Self.logQuoted(AppDiagnostics.compactText(normalized, limit: 1200))) \(segmentSummaries)"
        )

        return TranscriptionOutput(
            rawText: text,
            text: normalized,
            containsOnlyPlaceholderTokens: placeholderOnly
        )
    }

    private static func normalizeTranscription(_ text: String) -> String {
        // Whisper models can emit bracketed control markers for silence/non-speech.
        // Those should not be treated as user-visible dictation.
        let placeholderTokens: Set<String> = [
            "[BLANK_AUDIO]",
            "[BLANK AUDIO]",
            "[NO_AUDIO]",
            "[NO AUDIO]",
            "[SILENCE]",
            "[MUSIC]",
            "[NOISE]"
        ]

        let cleaned = text
            .split(whereSeparator: \.isWhitespace)
            .filter { !placeholderTokens.contains($0.uppercased()) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private static func containsOnlyPlaceholderTokens(in text: String) -> Bool {
        let tokens = text
            .split(whereSeparator: \.isWhitespace)
            .map { $0.uppercased() }

        guard !tokens.isEmpty else { return false }

        let placeholderTokens: Set<String> = [
            "[BLANK_AUDIO]",
            "[BLANK AUDIO]",
            "[NO_AUDIO]",
            "[NO AUDIO]",
            "[SILENCE]",
            "[MUSIC]",
            "[NOISE]"
        ]

        return tokens.allSatisfy { placeholderTokens.contains($0) }
    }

    private static func logQuoted(_ text: String) -> String {
        if text.isEmpty { return "\"\"" }
        return "\"\(text)\""
    }

    private static func selectModel() -> ModelSelection {
        let recommended = WhisperKit.recommendedModels()

        if recommended.default == slowStartupDefaultVariant,
           recommended.supported.contains(reliabilityFallbackVariant) {
            return ModelSelection(
                variant: reliabilityFallbackVariant,
                whisperKitDefault: recommended.default,
                reason: "reliability-override-slow-startup-default"
            )
        }

        return ModelSelection(
            variant: recommended.default,
            whisperKitDefault: recommended.default,
            reason: "whisperkit-default"
        )
    }

    private static func modelPolicySummary(for selection: ModelSelection) -> String {
        if selection.reason == "whisperkit-default" {
            return "Using WhisperKit's recommended model for this Mac."
        }

        return "Using \(selection.variant) for faster startup because WhisperKit's \(selection.whisperKitDefault) default was too slow for DICTATR on this Mac class."
    }

    private func handleDownloadProgress(_ progress: Progress, variant: String) {
        let fractionCompleted = progress.fractionCompleted
        downloadProgress = fractionCompleted

        if fractionCompleted > 0, loadingPhase != "Downloading model..." {
            loadingPhase = "Downloading model..."
            loadingDetail = "Downloading WhisperKit model files for \(variant)."
            AppDiagnostics.info(.transcriptionEngine, "Model download started variant=\(variant)")
        }

        while fractionCompleted >= nextDownloadLogThreshold, nextDownloadLogThreshold <= 1.0 {
            AppDiagnostics.info(
                .transcriptionEngine,
                "Model download progress variant=\(variant) progress=\(Self.progressString(nextDownloadLogThreshold))"
            )
            nextDownloadLogThreshold += 0.1
        }
    }

    private func startLoadHeartbeat(variant: String, startedAt: Date, compiledCacheExistedAtStart: Bool) {
        stopLoadHeartbeat()
        loadHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.isLoading else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                if self.loadingPhase == "Compiling on-device model...",
                   elapsed >= Self.compileWarningThreshold,
                   !self.hasLoggedWarmCompileWarning {
                    self.hasLoggedWarmCompileWarning = true
                    let compileKind = compiledCacheExistedAtStart ? "Warm launch" : "Cold compile"
                    self.loadingDetail = "\(compileKind) is taking unusually long. If this launch is force-quit, the next launch will clear the compiled cache automatically."
                    AppDiagnostics.warning(
                        .transcriptionEngine,
                        "Compile exceeded expected duration elapsed=\(Self.durationString(elapsed)) compiledCacheExistedAtStart=\(compiledCacheExistedAtStart ? "yes" : "no") nextLaunchRecovery=clearCompiledCache manualRecoveryCommand=\"\(Self.compiledCacheResetCommand())\" compiledCache=\(Self.compiledCacheSummary())"
                    )
                }
                AppDiagnostics.warning(
                    .transcriptionEngine,
                    "Model load still running variant=\(variant) phase=\(self.loadingPhase) progress=\(Self.progressString(self.downloadProgress)) elapsed=\(Self.durationString(elapsed)) detail=\(self.loadingDetail) compiledCache=\(Self.compiledCacheSummary())"
                )
            }
        }
    }

    private func stopLoadHeartbeat() {
        loadHeartbeatTask?.cancel()
        loadHeartbeatTask = nil
    }

    private func resetLoadingState() {
        stopLoadHeartbeat()
        isLoading = false
        loadingPhase = ""
        loadingDetail = ""
        downloadProgress = 0
        nextDownloadLogThreshold = 0.1
        hasLoggedWarmCompileWarning = false
    }

    private static func compiledCacheSummary() -> String {
        guard let cacheURL = compiledCacheURL() else {
            return "unavailable"
        }

        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return "missing path=\(cacheURL.path)"
        }

        return "path=\(cacheURL.path) exists=yes"
    }

    private static func compiledCacheURL() -> URL? {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let bundleID = Bundle.main.bundleIdentifier ?? "com.dictatr"
        return cacheRoot?
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
    }

    private static func compiledCacheExists() -> Bool {
        guard let cacheURL = compiledCacheURL() else {
            return false
        }

        return FileManager.default.fileExists(atPath: cacheURL.path)
    }

    private static func compiledCacheResetCommand() -> String {
        "rm -rf ~/Library/Caches/com.hannojacobs.DICTATR/com.apple.e5rt.e5bundlecache"
    }

    private static func modelLoadRecoveryStateURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return appSupport
            .appendingPathComponent("DICTATR", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("model-load-recovery.json", isDirectory: false)
    }

    private static func persistModelLoadRecoveryState(
        variant: String,
        stage: String,
        startedAt: Date,
        compiledCacheExistedAtStart: Bool
    ) {
        guard let stateURL = modelLoadRecoveryStateURL() else {
            return
        }

        let state = ModelLoadRecoveryState(
            variant: variant,
            stage: stage,
            launchSessionID: AppDiagnostics.launchSessionID,
            startedAt: startedAt,
            updatedAt: Date(),
            osBuild: currentOSBuild(),
            compiledCacheExistedAtStart: compiledCacheExistedAtStart
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            AppDiagnostics.warning(
                .transcriptionEngine,
                "Failed to persist model load recovery state path=\(stateURL.path) error=\(error.localizedDescription)"
            )
        }
    }

    private static func clearModelLoadRecoveryState() {
        guard let stateURL = modelLoadRecoveryStateURL(),
              FileManager.default.fileExists(atPath: stateURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: stateURL)
        } catch {
            AppDiagnostics.warning(
                .transcriptionEngine,
                "Failed to clear model load recovery state path=\(stateURL.path) error=\(error.localizedDescription)"
            )
        }
    }

    private static func recoverFromInterruptedCompileIfNeeded(for variant: String) {
        guard let stateURL = modelLoadRecoveryStateURL(),
              let data = try? Data(contentsOf: stateURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let state = try? decoder.decode(ModelLoadRecoveryState.self, from: data) else {
            AppDiagnostics.warning(
                .transcriptionEngine,
                "Ignoring unreadable model load recovery state path=\(stateURL.path)"
            )
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        defer { try? FileManager.default.removeItem(at: stateURL) }

        guard state.stage == ModelLoadStage.compiling,
              state.variant == variant,
              state.osBuild == currentOSBuild() else {
            return
        }

        let age = Date().timeIntervalSince(state.updatedAt)
        AppDiagnostics.warning(
            .transcriptionEngine,
            "Recovering from interrupted compile previousLaunchSession=\(state.launchSessionID) previousStage=\(state.stage) previousCompiledCacheExistedAtStart=\(state.compiledCacheExistedAtStart ? "yes" : "no") age=\(durationString(age)) action=clearCompiledCache compiledCache=\(compiledCacheSummary())"
        )

        if let cacheURL = compiledCacheURL(), FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                try FileManager.default.removeItem(at: cacheURL)
                AppDiagnostics.info(
                    .transcriptionEngine,
                    "Compiled cache cleared after interrupted compile path=\(cacheURL.path)"
                )
            } catch {
                AppDiagnostics.warning(
                    .transcriptionEngine,
                    "Failed to clear compiled cache after interrupted compile path=\(cacheURL.path) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private static func currentOSBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }

        return String(cString: buffer)
    }

    private static func cachedModelFolder(for variant: String) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let modelFolder = documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)

        guard FileManager.default.fileExists(atPath: modelFolder.path) else {
            return nil
        }

        let requiredEntries = [
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc"
        ]

        guard requiredEntries.allSatisfy({ FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0).path) }) else {
            return nil
        }

        return modelFolder
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        if interval >= 60 {
            return String(format: "%.2fs (%.1fm)", interval, interval / 60)
        }

        return String(format: "%.2fs", interval)
    }

    private static func progressString(_ fractionCompleted: Double) -> String {
        let percentage = max(0, min(100, Int((fractionCompleted * 100).rounded())))
        return "\(percentage)%"
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
