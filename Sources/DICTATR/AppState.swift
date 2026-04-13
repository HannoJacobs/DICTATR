// AppState.swift
//
// Central application state and pipeline orchestrator.
// Drives the full dictation lifecycle: idle → recording → transcribing → idle
//
// STATE MANAGEMENT:
//   @Observable + @MainActor: all mutations happen on the main thread.
//   SwiftUI views re-render automatically when observed stored properties change.
//   Computed properties are NOT tracked by @Observable — use stored properties with
//   didSet for UserDefaults-backed values (see autoPasteEnabled, retentionCount).
//
// STARTUP SEQUENCE:
//   1. init()              — register defaults, open DB, register hotkey, start model download
//   2. startModelDownload() — TranscriptionEngine.loadModel() in a Task
//   3. DICTATRApp keeps the menu available while the model loads in the background
//   4. When isModelLoaded becomes true → hotkey recording becomes available
//
// RECORDING PIPELINE:
//   toggleRecording() → startRecording()
//     → AVAudioEngine tap writes 16kHz WAV to temp dir
//     → RecordingIndicatorPanel shown (floating overlay)
//   toggleRecording() → stopRecordingAndTranscribe()
//     → WAV file → WhisperKit → text
//     → PasteManager.paste() (clipboard + Cmd+V if accessibility granted)
//     → DatabaseManager.save() + deleteOld()
//     → temp WAV file deleted
//
// TEMP FILE CLEANUP:
//   Every code path deletes the WAV file — success, failure, cancellation, too-short.
//   If the app crashes mid-transcription, the OS clears temp dir eventually.

import AVFoundation
import AppKit
import Foundation
import KeyboardShortcuts
import os
import SwiftUI

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
}

@Observable
@MainActor
final class AppState {
    private static let logger = Logger(subsystem: "com.dictatr", category: "AppState")

    var currentState: DictationState = .idle {
        didSet {
            logObservableChange(
                name: "currentState",
                oldValue: String(describing: oldValue),
                newValue: String(describing: currentState)
            )
        }
    }
    var lastTranscription: String? {
        didSet {
            logObservableChange(
                name: "lastTranscription",
                oldValue: oldValue.map { "chars=\($0.count) text=\(AppDiagnostics.quoted($0, limit: 800))" } ?? "nil",
                newValue: lastTranscription.map { "chars=\($0.count) text=\(AppDiagnostics.quoted($0, limit: 800))" } ?? "nil"
            )
        }
    }
    var statusMessage: String = "Ready" {
        didSet {
            logObservableChange(name: "statusMessage", oldValue: AppDiagnostics.quoted(oldValue), newValue: AppDiagnostics.quoted(statusMessage))
        }
    }
    var errorMessage: String? {
        didSet {
            logObservableChange(
                name: "errorMessage",
                oldValue: AppDiagnostics.optionalQuoted(oldValue),
                newValue: AppDiagnostics.optionalQuoted(errorMessage)
            )
        }
    }

    // Stored properties with didSet so @Observable tracks changes correctly.
    // Computed properties are NOT instrumented by @Observable, so using them
    // would cause SwiftUI views to never re-render on value changes.
    var autoPasteEnabled: Bool = {
        // register(defaults:) runs in init() — too late for stored property initializers.
        // Check explicitly so the first-launch default is true.
        if UserDefaults.standard.object(forKey: "autoPasteEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "autoPasteEnabled")
    }() {
        didSet {
            UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled")
            logObservableChange(
                name: "autoPasteEnabled",
                oldValue: String(oldValue),
                newValue: String(autoPasteEnabled)
            )
        }
    }

    var retentionCount: Int = {
        let count = UserDefaults.standard.integer(forKey: "retentionCount")
        return count > 0 ? count : 10
    }() {
        didSet {
            retentionCount = max(1, retentionCount)
            UserDefaults.standard.set(retentionCount, forKey: "retentionCount")
            logObservableChange(
                name: "retentionCount",
                oldValue: String(oldValue),
                newValue: String(retentionCount)
            )
        }
    }

    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
            logObservableChange(
                name: "hasCompletedOnboarding",
                oldValue: String(oldValue),
                newValue: String(hasCompletedOnboarding)
            )
        }
    }

    let audioRecorder = AudioRecorder()
    let transcriptionEngine = TranscriptionEngine()
    let databaseManager: DatabaseManager?

    private var hotkeyManager: HotkeyManager?
    private var httpServer: LocalHTTPServer?
    private var modelLoadTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var autoRetryTask: Task<Void, Never>?
    private var autoRetryCount = 0
    /// True while a reconnect retry is scheduled or sleeping. Prevents an HFP "storm"
    /// (many `onRecordingFailed` callbacks in one burst) from burning the whole retry budget.
    private var recordingRecoveryPending = false
    private let recordingIndicator = RecordingIndicatorPanel()

    var menuBarIcon: String {
        switch currentState {
        case .idle:
            return "mic"
        case .recording:
            return "mic.fill"
        case .transcribing:
            return "ellipsis.circle"
        }
    }

    var isModelLoaded: Bool { transcriptionEngine.isModelLoaded }
    var isModelLoading: Bool { transcriptionEngine.isLoading }
    var configuredModelVariant: String { transcriptionEngine.configuredModelVariant }
    var configuredModelPolicySummary: String { transcriptionEngine.configuredModelPolicySummary }
    var canHardResetAudio: Bool { currentState != .transcribing }

    private func logObservableChange(name: String, oldValue: String, newValue: String) {
        guard oldValue != newValue else { return }
        AppDiagnostics.info(
            .appState,
            "state change field=\(name) old=\(oldValue) new=\(newValue) snapshot={\(stateSnapshot())}"
        )
    }

    private func stateSnapshot() -> String {
        [
            "currentState=\(String(describing: currentState))",
            "statusMessage=\(AppDiagnostics.quoted(statusMessage, limit: 200))",
            "errorMessage=\(AppDiagnostics.optionalQuoted(errorMessage, limit: 200))",
            "lastTranscriptionChars=\(lastTranscription?.count ?? 0)",
            "isModelLoaded=\(AppDiagnostics.boolLabel(transcriptionEngine.isModelLoaded))",
            "isModelLoading=\(AppDiagnostics.boolLabel(transcriptionEngine.isLoading))",
            "autoPasteEnabled=\(AppDiagnostics.boolLabel(autoPasteEnabled))",
            "retentionCount=\(retentionCount)",
            "retryCount=\(autoRetryCount)",
            "recoveryPending=\(AppDiagnostics.boolLabel(recordingRecoveryPending))",
            AppDiagnostics.threadSummary(),
            AppDiagnostics.frontmostAppSummary(),
            AudioDeviceDiagnostics.currentRouteSnapshot()
        ].joined(separator: " ")
    }

    init() {
        // Register defaults (idempotent, never overwrites explicit user choices)
        UserDefaults.standard.register(defaults: ["autoPasteEnabled": true])

        // One-time migration: reset shortcut to new F5 default
        if !UserDefaults.standard.bool(forKey: "shortcutMigratedToF5") {
            KeyboardShortcuts.reset(.toggleDictation)
            UserDefaults.standard.set(true, forKey: "shortcutMigratedToF5")
        }

        // Initialize database, fail gracefully but notify user
        do {
            self.databaseManager = try DatabaseManager()
        } catch {
            print("Failed to initialize database: \(error)")
            AppDiagnostics.error(.appState, "Database initialization failed error=\(error.localizedDescription)")
            self.databaseManager = nil
            self.errorMessage = "History unavailable: database failed to load."
        }

        AppDiagnostics.info(
            .appState,
            "AppState initialized \(AppDiagnostics.runtimeSummary) autoPasteEnabled=\(autoPasteEnabled) retentionCount=\(retentionCount) onboardingComplete=\(hasCompletedOnboarding) databaseAvailable=\(databaseManager != nil) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        AppDiagnostics.info(
            .audioDevices,
            "AppState audio snapshot route=\(AudioDeviceDiagnostics.currentRouteSnapshot()) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )

        // Wire up auto-stop callback from AudioRecorder (watchdog timeout, engine failure)
        audioRecorder.onRecordingFailed = { [weak self] message in
            self?.handleRecordingFailure(message: message)
        }

        // Reset retry counter once recording is confirmed stable (5s watchdog passed).
        // This ensures long-running sessions get fresh retries for each new glitch,
        // rather than exhausting the counter from a single burst of config changes.
        audioRecorder.onRecordingStable = { [weak self] in
            guard let self else { return }
            if self.autoRetryCount > 0 {
                AppDiagnostics.info(
                    .appState,
                    "Recording stable — resetting retry counter from \(self.autoRetryCount) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
                )
                self.autoRetryCount = 0
            }
        }

        // Register hotkey — dispatch to MainActor since callback thread is unspecified
        hotkeyManager = HotkeyManager { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

        // Start local HTTP transcription server (localhost:9876).
        // The closure checks isModelLoaded before transcribing — requests that arrive
        // before the model is ready get a 500 "model not loaded" response.
        httpServer = LocalHTTPServer { [weak self] url in
            guard let self else { throw TranscriptionError.modelNotLoaded }
            let engine = try await self.httpTranscriptionEngine()
            return try await engine.transcribe(audioURL: url)
        }
        httpServer?.start()

        // Start model download immediately so it's ready when user opens the menu.
        // If already cached, this completes in seconds.
        startModelDownload()
    }

    func startModelDownload() {
        guard !transcriptionEngine.isLoading, !transcriptionEngine.isModelLoaded else { return }
        modelLoadTask?.cancel()
        modelLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                AppDiagnostics.info(.appState, "Model load started")
                self.statusMessage = "Loading model..."
                try await self.transcriptionEngine.loadModel()
                if Task.isCancelled { return }
                self.statusMessage = "Ready"
                self.errorMessage = nil
                AppDiagnostics.info(.appState, "Model load completed successfully")
            } catch {
                if Task.isCancelled { return }
                self.statusMessage = "Model load failed"
                self.errorMessage = "Model load failed: \(error.localizedDescription)"
                AppDiagnostics.error(.appState, "Model load failed error=\(error.localizedDescription)")
            }
        }
    }

    func retryModelLoad() {
        guard !transcriptionEngine.isLoading else {
            AppDiagnostics.warning(.appState, "retryModelLoad ignored because model load is already in progress")
            errorMessage = "Model load is already in progress."
            return
        }

        AppDiagnostics.info(.appState, "retryModelLoad requested")
        errorMessage = nil
        statusMessage = "Loading model..."
        startModelDownload()
    }

    func hardResetAudioContention() {
        guard currentState != .transcribing else {
            AppDiagnostics.warning(.appState, "hardResetAudioContention ignored during transcription")
            errorMessage = "Wait for transcription to finish before resetting audio."
            return
        }

        AppDiagnostics.warning(
            .appState,
            "hardResetAudioContention requested currentState=\(String(describing: currentState)) retryCount=\(autoRetryCount) recoveryPending=\(recordingRecoveryPending) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )

        autoRetryTask?.cancel()
        autoRetryTask = nil
        recordingRecoveryPending = false
        autoRetryCount = 0
        audioRecorder.forceReset(reason: "user requested hard audio reset")
        recordingIndicator.hide()
        currentState = .idle

        let result = AudioContentionReset.killLikelyContenders(excluding: [Int32(ProcessInfo.processInfo.processIdentifier)])

        if let inspectionFailure = result.inspectionFailure {
            statusMessage = "Audio reset failed"
            errorMessage = inspectionFailure
            AppDiagnostics.error(.appState, "hard audio reset process inspection failed error=\(inspectionFailure)")
            return
        }

        for killed in result.killed {
            AppDiagnostics.warning(.appState, "hard audio reset killed pid=\(killed.pid) details=\(killed.description)")
        }

        for skipped in result.skipped {
            AppDiagnostics.warning(.appState, "hard audio reset skipped \(skipped)")
        }

        statusMessage = "Audio reset complete"
        if !result.killed.isEmpty {
            let suffix = result.killed.count == 1 ? "process" : "processes"
            errorMessage = "Killed \(result.killed.count) external audio \(suffix). Try dictation again."
        } else if !result.skipped.isEmpty {
            errorMessage = "Found external audio processes, but DICTATR could not terminate all of them."
        } else {
            errorMessage = "No external Chromium or Electron audio helpers were running."
        }

        AppDiagnostics.info(
            .appState,
            "hard audio reset completed killed=\(result.killed.count) skipped=\(result.skipped.count) message=\(errorMessage ?? "none") route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
    }

    func toggleRecording() {
        AppDiagnostics.info(
            .appState,
            "toggleRecording currentState=\(String(describing: currentState)) retryCount=\(autoRetryCount) recoveryPending=\(recordingRecoveryPending) snapshot={\(stateSnapshot())}"
        )
        switch currentState {
        case .idle:
            if recordingRecoveryPending {
                statusMessage = "Reconnecting..."
                errorMessage = "Microphone recovery is already in progress. Please wait."
                AppDiagnostics.warning(
                    .appState,
                    "toggleRecording ignored because microphone recovery is already pending retryCount=\(autoRetryCount) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
                )
                return
            }
            autoRetryCount = 0
            recordingRecoveryPending = false
            autoRetryTask?.cancel()
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            // Ignore while transcribing
            break
        }
    }

    private func startRecording() {
        guard transcriptionEngine.isModelLoaded else {
            if !transcriptionEngine.isLoading {
                AppDiagnostics.info(.appState, "startRecording triggered model load because model is not ready")
                statusMessage = "Loading model..."
                errorMessage = "Model is loading. Please wait."
                startModelDownload()
            } else {
                errorMessage = "Model is still loading. Please wait."
                AppDiagnostics.warning(.appState, "startRecording blocked because model is still loading")
            }
            return
        }

        AppDiagnostics.info(
            .appState,
            "startRecording requested retryCount=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        do {
            let url = try audioRecorder.startRecording()
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
            NSSound(named: .init("Tink"))?.play()
            recordingIndicator.show(audioRecorder: audioRecorder)
            AppDiagnostics.info(
                .appState,
                "recording started session=\(audioRecorder.recordingSessionID ?? "none") file=\(url.lastPathComponent) snapshot={\(stateSnapshot())}"
            )
        } catch {
            currentState = .idle
            statusMessage = "Ready"
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            AppDiagnostics.error(
                .appState,
                "recording failed to start error=\(error.localizedDescription) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
            )
        }
    }

    // Recovery strategy: stay on the active system route and retry after a short delay.
    // Max 3 failure *events* (after coalescing). A reboot "fixes" Bluetooth/HFP because
    // Core Audio clears stuck state; we approximate that with longer settle delays after
    // route-churn messages, not by rebooting the Mac (apps can't).
    private func handleRecordingFailure(message: String) {
        if recordingRecoveryPending {
            AppDiagnostics.warning(
                .appState,
                "Ignoring duplicate recording failure while recovery already scheduled message=\(message) retryCount=\(autoRetryCount) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            return
        }

        AppDiagnostics.error(
            .appState,
            "Recording auto-stopped session=\(audioRecorder.recordingSessionID ?? "none") message=\(AppDiagnostics.quoted(message, limit: 400)) retryCountBeforeIncrement=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        autoRetryCount += 1

        if autoRetryCount > 3 {
            AppDiagnostics.error(
                .appState,
                "Exceeded max retries retryCount=\(self.autoRetryCount) snapshot={\(stateSnapshot())} availableDevices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
            )
            recordingRecoveryPending = false
            autoRetryTask?.cancel()
            currentState = .idle
            statusMessage = "Recording failed"
            errorMessage = "Microphone unavailable. Try disconnecting and reconnecting your headphones."
            recordingIndicator.hide()
            return
        }

        let delaySeconds = Self.delayBeforeReconnectAttempt(message: message, attempt: autoRetryCount)

        AppDiagnostics.warning(
            .appState,
            "Scheduling retry on current route delay=\(String(format: "%.1f", delaySeconds))s retryCount=\(autoRetryCount) message=\(AppDiagnostics.quoted(message, limit: 400)) snapshot={\(stateSnapshot())}"
        )
        currentState = .idle
        statusMessage = "Reconnecting..."
        recordingIndicator.showReconnecting()

        recordingRecoveryPending = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self else { return }
            guard !Task.isCancelled, self.currentState == .idle else {
                self.recordingRecoveryPending = false
                AppDiagnostics.info(.appState, "Route retry cancelled before execution")
                return
            }
            self.recordingRecoveryPending = false
            self.retryStartRecording()
        }
    }

    /// Longer delay after route / HFP churn (similar to what a reboot indirectly provides: time to settle).
    private static func delayBeforeReconnectAttempt(message: String, attempt: Int) -> TimeInterval {
        let routeChurn =
            message.localizedCaseInsensitiveContains("audio device") ||
            message.localizedCaseInsensitiveContains("reconnecting") ||
            message.localizedCaseInsensitiveContains("device changed")

        if attempt == 1 {
            return routeChurn ? 2.5 : 1.0
        }
        return routeChurn ? 2.0 : 1.5
    }

    private func retryStartRecording() {
        guard transcriptionEngine.isModelLoaded else { return }
        AppDiagnostics.info(
            .appState,
            "retryStartRecording retryCount=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )

        do {
            let url = try audioRecorder.startRecording()
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
            recordingIndicator.show(audioRecorder: audioRecorder)
            AppDiagnostics.info(
                .appState,
                "retry succeeded session=\(audioRecorder.recordingSessionID ?? "none") file=\(url.lastPathComponent) snapshot={\(stateSnapshot())}"
            )
        } catch {
            AppDiagnostics.error(
                .appState,
                "retry failed error=\(error.localizedDescription) retryCount=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
            )
            handleRecordingFailure(message: error.localizedDescription)
        }
    }

    private func httpTranscriptionEngine() throws -> TranscriptionEngine {
        guard transcriptionEngine.isModelLoaded else {
            throw TranscriptionError.modelNotLoaded
        }
        return transcriptionEngine
    }

    private func stopRecordingAndTranscribe() {
        let sessionID = audioRecorder.recordingSessionID ?? "none"
        AppDiagnostics.info(
            .appState,
            "stopRecordingAndTranscribe requested session=\(sessionID) snapshot={\(stateSnapshot())}"
        )
        NSSound(named: .init("Pop"))?.play()
        guard let result = audioRecorder.stopRecording() else {
            // Reset to idle if stop fails — force-reset ensures full cleanup
            AppDiagnostics.error(
                .appState,
                "stopRecording returned nil session=\(sessionID) — force resetting recorder"
            )
            audioRecorder.forceReset(reason: "AppState stopRecordingAndTranscribe nil result")
            recordingIndicator.hide()
            currentState = .idle
            statusMessage = "Recording failed"
            return
        }

        AppDiagnostics.info(
            .appState,
            "recording stopped session=\(sessionID) duration=\(String(format: "%.3f", result.duration))s frames=\(result.framesWritten) file=\(result.url.lastPathComponent) snapshot={\(stateSnapshot())}"
        )

        if let signalStats = Self.analyzeAudioSignal(at: result.url) {
            AppDiagnostics.info(
                .appState,
                "recording signal session=\(sessionID) rms=\(String(format: "%.6f", signalStats.rms)) peak=\(String(format: "%.6f", signalStats.peak)) samples=\(signalStats.sampleCount)"
            )
        } else {
            AppDiagnostics.warning(
                .appState,
                "recording signal analysis unavailable session=\(sessionID) file=\(result.url.lastPathComponent)"
            )
        }

        // Skip transcription for empty or trivially short recordings
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        if result.duration < 0.3 || fileSize < 1000 {
            AppDiagnostics.info(
                .appState,
                "recording too short session=\(sessionID) duration=\(String(format: "%.3f", result.duration))s fileSize=\(fileSize)B — skipping transcription"
            )
            recordingIndicator.hide()
            statusMessage = "Recording too short"
            currentState = .idle
            try? FileManager.default.removeItem(at: result.url)
            return
        }

        // Detect hardware/driver issues where recording ran but no audio was captured
        if result.framesWritten < 800 { // ~50ms at 16kHz
            AppDiagnostics.warning(
                .appState,
                "no audio captured session=\(sessionID) frames=\(result.framesWritten) duration=\(String(format: "%.3f", result.duration))s fileSize=\(fileSize)B route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            recordingIndicator.hide()
            statusMessage = "No audio captured. Check your microphone."
            currentState = .idle
            try? FileManager.default.removeItem(at: result.url)
            return
        }

        recordingIndicator.showProcessing()
        currentState = .transcribing
        statusMessage = "Transcribing..."

        // Cancel any lingering previous transcription task
        transcriptionTask?.cancel()

        transcriptionTask = Task { [weak self] in
            do {
                guard let self else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }
                let text = try await self.transcriptionEngine.transcribe(audioURL: result.url)
                AppDiagnostics.info(
                    .appState,
                    "transcription returned session=\(sessionID) chars=\(text.count) text=\(AppDiagnostics.quoted(text, limit: 1200)) file=\(result.url.lastPathComponent) snapshot={\(self.stateSnapshot())}"
                )

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                if text.isEmpty {
                    AppDiagnostics.info(.appState, "transcription returned empty text session=\(sessionID)")
                    self.recordingIndicator.hide()
                    self.statusMessage = "No speech detected"
                    self.currentState = .idle
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                AppDiagnostics.info(
                    .appState,
                    "transcription complete session=\(sessionID) chars=\(text.count) text=\(AppDiagnostics.quoted(text, limit: 1200)) snapshot={\(self.stateSnapshot())}"
                )
                self.lastTranscription = text

                // Paste to active app
                let pasteResult = await PasteManager.paste(text: text, autoPaste: self.autoPasteEnabled)
                AppDiagnostics.info(
                    .appState,
                    "paste result session=\(sessionID) result=\(String(describing: pasteResult)) snapshot={\(self.stateSnapshot())}"
                )

                if pasteResult == .noAccessibility {
                    self.errorMessage = "Settings → search \"Privacy\" → Accessibility → toggle DICTATR on"
                }

                // Save to database — don't let DB failure undo the transcription
                if let db = self.databaseManager {
                    do {
                        var record = DictationRecord(
                            text: text,
                            duration: result.duration,
                            audioFilePath: nil,
                            createdAt: Date()
                        )
                        try db.save(&record)
                        try db.deleteOld(keepLast: self.retentionCount)
                    } catch {
                        self.errorMessage = "Failed to save to history: \(error.localizedDescription)"
                        AppDiagnostics.error(
                            .appState,
                            "failed to save history session=\(sessionID) error=\(error.localizedDescription) snapshot={\(self.stateSnapshot())}"
                        )
                    }
                }

                // Clean up temp audio file after transcription
                try? FileManager.default.removeItem(at: result.url)

                self.recordingIndicator.showDone(pasted: pasteResult == .pasted)
                NSSound(named: .init("Glass"))?.play()
                if pasteResult != .noAccessibility {
                    self.errorMessage = nil
                }
                self.statusMessage = "Done"
                self.currentState = .idle

            } catch {
                // Clean up temp audio file on failure
                try? FileManager.default.removeItem(at: result.url)
                guard let self else { return }
                AppDiagnostics.error(
                    .appState,
                    "transcription failed session=\(sessionID) error=\(error.localizedDescription) snapshot={\(self.stateSnapshot())}"
                )
                self.recordingIndicator.hide()
                self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                self.statusMessage = "Error"
                self.currentState = .idle
            }
        }
    }

    func copyToClipboard(_ text: String) {
        AppDiagnostics.info(
            .appState,
            "copyToClipboard chars=\(text.count) text=\(AppDiagnostics.quoted(text, limit: 1000)) \(AppDiagnostics.frontmostAppSummary())"
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension UserDefaults {
    func contains(key: String) -> Bool {
        object(forKey: key) != nil
    }
}

private extension AppState {
    static func analyzeAudioSignal(at url: URL) -> (rms: Float, peak: Float, sampleCount: Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return nil
        }

        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        let samples = Int(buffer.frameLength)
        guard samples > 0 else { return nil }

        let channel = channelData[0]
        var sumSquares: Float = 0
        var peak: Float = 0

        for index in 0..<samples {
            let value = channel[index]
            sumSquares += value * value
            peak = max(peak, abs(value))
        }

        let rms = sqrt(sumSquares / Float(samples))
        return (rms, peak, samples)
    }
}
