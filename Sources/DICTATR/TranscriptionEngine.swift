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

    private(set) var isModelLoaded = false
    private(set) var isLoading = false
    private(set) var downloadProgress: Double = 0
    private(set) var loadingPhase: String = ""
    private(set) var loadingDetail: String = ""

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
            // Use WhisperKit's recommended model for this device
            let recommended = WhisperKit.recommendedModels()
            let variant = recommended.default
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
