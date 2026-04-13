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
//     → AVCaptureSession audio output writes native mic samples
//     → AVAudioConverter writes 16kHz WAV to temp dir
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
            RecordingDiagnostics.shared.setRecorderState(currentState)
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
    var microphonePermissionStatus: MicrophoneAuthorizationState = MicrophonePermissionManager.authorizationState() {
        didSet {
            logObservableChange(
                name: "microphonePermissionStatus",
                oldValue: oldValue.rawValue,
                newValue: microphonePermissionStatus.rawValue
            )
        }
    }

    let audioRecorder = AudioRecorder()
    let transcriptionEngine = TranscriptionEngine()
    let databaseManager: DatabaseManager?

    private let audioRouteObserver: AudioRouteObserver
    private var hotkeyManager: HotkeyManager?
    private var httpServer: LocalHTTPServer?
    private var modelLoadTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var autoRetryTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var autoRetryCount = 0
    private var activeRecoveryCycleID: String?
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
    var shouldShowOnboarding: Bool { !hasCompletedOnboarding || !microphonePermissionStatus.isAuthorized }

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
            "microphoneStatus=\(microphonePermissionStatus.rawValue)",
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
        self.audioRouteObserver = AudioRouteObserver()
        RecordingDiagnostics.shared.setRecorderState(.idle)

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

        refreshPermissionStates(source: "init")

        // Wire up auto-stop callback from AudioRecorder (watchdog timeout, engine failure)
        audioRecorder.onRecordingFailed = { [weak self] event in
            self?.handleRecordingFailure(event: event)
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

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionStates(source: "appDidBecomeActive")
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
            let output = try await engine.transcribe(audioURL: url)
            return output.text
        }
        httpServer?.start()

        // Start model download immediately so it's ready when user opens the menu.
        // If already cached, this completes in seconds.
        startModelDownload()
    }

    func refreshPermissionStates(source: String = "unspecified") {
        let previousStatus = microphonePermissionStatus
        let refreshedStatus = MicrophonePermissionManager.authorizationState()
        let level: (DiagnosticCategory, String) -> Void = previousStatus == refreshedStatus ? AppDiagnostics.debug : AppDiagnostics.info
        level(
            .appState,
            "microphone permission refresh source=\(source) previous=\(previousStatus.rawValue) current=\(refreshedStatus.rawValue)"
        )
        microphonePermissionStatus = refreshedStatus
    }

    func handleMicrophonePermissionAction(source: String) async {
        refreshPermissionStates(source: "\(source):preAction")
        switch microphonePermissionStatus {
        case .authorized:
            AppDiagnostics.info(.appState, "Microphone permission already authorized source=\(source)")
            errorMessage = nil
        case .notDetermined:
            AppDiagnostics.info(.appState, "Requesting microphone permission source=\(source)")
            statusMessage = "Requesting microphone access..."
            let granted = await MicrophonePermissionManager.requestAccess(source: source)
            refreshPermissionStates(source: "\(source):postPrompt")
            if granted {
                AppDiagnostics.info(.appState, "Microphone permission granted source=\(source)")
                if currentState == .idle, !isModelLoading {
                    statusMessage = "Ready"
                }
                errorMessage = nil
            } else {
                AppDiagnostics.warning(.appState, "Microphone permission denied at prompt source=\(source)")
                statusMessage = "Microphone access required"
                errorMessage = "Settings → search \"Privacy\" → Microphone → toggle DICTATR on"
            }
        case .denied, .restricted:
            AppDiagnostics.warning(
                .appState,
                "Opening microphone settings source=\(source) status=\(microphonePermissionStatus.rawValue)"
            )
            statusMessage = "Microphone access required"
            errorMessage = microphonePermissionStatus == .restricted
                ? "Microphone access is restricted by macOS or device policy."
                : "Settings → search \"Privacy\" → Microphone → toggle DICTATR on"
            MicrophonePermissionManager.openSettings(source: source)
        }
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

    func toggleRecording() {
        RecordingDiagnostics.shared.setRecorderState(currentState)
        AppDiagnostics.info(
            .appState,
            "toggleRecording context={\(RecordingDiagnostics.shared.contextSnapshot())} currentState=\(String(describing: currentState)) retryCount=\(autoRetryCount) recoveryPending=\(recordingRecoveryPending) snapshot={\(stateSnapshot())}"
        )
        switch currentState {
        case .idle:
            if recordingStartTask != nil || audioRecorder.isRecording {
                statusMessage = microphonePermissionStatus == .notDetermined ? "Requesting microphone access..." : "Starting recording..."
                errorMessage = "Recording start is already in progress. Please wait."
                AppDiagnostics.warning(.appState, "toggleRecording ignored because recording start is already in progress")
                return
            }
            if recordingRecoveryPending {
                RecordingDiagnostics.shared.recordRetryDecision(
                    .duplicateFailureCoalesced,
                    detail: "cause=user_hotkey snapshot={\(stateSnapshot())}"
                )
                statusMessage = "Reconnecting..."
                errorMessage = "Microphone recovery is already in progress. Please wait."
                AppDiagnostics.warning(
                    .appState,
                    "toggleRecording ignored because microphone recovery is already pending context={\(RecordingDiagnostics.shared.contextSnapshot())} retryCount=\(autoRetryCount) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
                )
                return
            }
            autoRetryCount = 0
            activeRecoveryCycleID = nil
            recordingRecoveryPending = false
            RecordingDiagnostics.shared.clearRecoveryState()
            autoRetryTask?.cancel()
            recordingStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.recordingStartTask = nil }
                await self.startRecording()
            }
        case .recording:
            RecordingDiagnostics.shared.recordRecorderEvent("manual_stop_requested", detail: "cause=user_hotkey context={\(RecordingDiagnostics.shared.contextSnapshot())}")
            stopRecordingAndTranscribe()
        case .transcribing:
            // Ignore while transcribing
            break
        }
    }

    private func startRecording() async {
        refreshPermissionStates(source: "startRecording")
        switch microphonePermissionStatus {
        case .authorized:
            break
        case .notDetermined:
            AppDiagnostics.info(.appState, "startRecording requesting microphone permission before capture")
            statusMessage = "Requesting microphone access..."
            errorMessage = nil
            let granted = await MicrophonePermissionManager.requestAccess(source: "startRecording")
            refreshPermissionStates(source: "startRecording:postPrompt")
            guard !Task.isCancelled else { return }
            guard granted, microphonePermissionStatus.isAuthorized else {
                statusMessage = "Microphone access required"
                errorMessage = "Settings → search \"Privacy\" → Microphone → toggle DICTATR on"
                AppDiagnostics.warning(.appState, "startRecording blocked because microphone permission was not granted")
                return
            }
        case .denied, .restricted:
            statusMessage = "Microphone access required"
            errorMessage = microphonePermissionStatus == .restricted
                ? "Microphone access is restricted by macOS or device policy."
                : "Settings → search \"Privacy\" → Microphone → toggle DICTATR on"
            AppDiagnostics.warning(
                .appState,
                "startRecording blocked because microphone access is unavailable status=\(microphonePermissionStatus.rawValue)"
            )
            return
        }

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

        statusMessage = "Starting recording..."
        errorMessage = nil
        AppDiagnostics.info(
            .appState,
            "startRecording requested context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["cause": "user_hotkey"]))} retryCount=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        do {
            let url = try await audioRecorder.startRecording(metadata: .userHotkey)
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
            NSSound(named: .init("Tink"))?.play()
            recordingIndicator.show(audioRecorder: audioRecorder)
            AppDiagnostics.info(
                .appState,
                "recording started \(AppDiagnostics.recordingVersionSummary) context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["cause": "user_hotkey"]))} session=\(audioRecorder.recordingSessionID ?? "none") file=\(url.lastPathComponent) snapshot={\(stateSnapshot())}"
            )
        } catch {
            currentState = .idle
            statusMessage = "Ready"
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            let reason = RecordingFailureReason.from(error: error)
            RecordingDiagnostics.shared.recordRecorderEvent(
                "attempt_failed_before_recording",
                detail: "reason=\(reason.rawValue) error=\(AppDiagnostics.quoted(error.localizedDescription))"
            )
            RecordingDiagnostics.shared.dumpBreadcrumbs(reason: "engine_start_failed")
            AppDiagnostics.error(
                .appState,
                "recording failed to start context={\(RecordingDiagnostics.shared.contextSnapshot())} reason=\(reason.rawValue) error=\(error.localizedDescription) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
            )
        }
    }

    // Recovery strategy: stay on the active system route and retry after a short delay.
    // Max 3 failure *events* (after coalescing). A reboot "fixes" Bluetooth/HFP because
    // Core Audio clears stuck state; we approximate that with longer settle delays after
    // route-churn messages, not by rebooting the Mac (apps can't).
    private func handleRecordingFailure(event: RecordingFailureEvent) {
        let sessionID = audioRecorder.recordingSessionID ?? "none"
        let recoveryCycleID = activeRecoveryCycleID ?? RecordingDiagnostics.shared.beginRecoveryCycleIfNeeded(recordingSessionID: sessionID)
        activeRecoveryCycleID = recoveryCycleID

        if recordingRecoveryPending {
            RecordingDiagnostics.shared.recordFailureEvent(
                RecordingFailureEvent(
                    reason: .duplicateFailureWhileRecoveryPending,
                    userMessage: RecordingFailureReason.duplicateFailureWhileRecoveryPending.defaultUserMessage,
                    framesWritten: event.framesWritten,
                    droppedFrames: event.droppedFrames,
                    routeState: event.routeState,
                    captureSnapshot: event.captureSnapshot,
                    detail: "originalReason=\(event.reason.rawValue) \(event.detail)"
                ),
                retryBudgetBefore: autoRetryCount,
                retryBudgetAfter: autoRetryCount,
                budgetConsumed: false,
                coalescedIntoExistingRecovery: true
            )
            RecordingDiagnostics.shared.recordRetryDecision(
                .duplicateFailureCoalesced,
                detail: "reason=\(event.reason.rawValue) retryBudgetBefore=\(autoRetryCount) retryBudgetAfter=\(autoRetryCount) recoveryCycle=\(recoveryCycleID)"
            )
            AppDiagnostics.warning(
                .appState,
                "Ignoring duplicate recording failure while recovery already scheduled context={\(RecordingDiagnostics.shared.contextSnapshot())} reason=\(event.reason.rawValue) retryCount=\(autoRetryCount) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            return
        }

        let retryBudgetBefore = autoRetryCount
        let retryBudgetAfter = autoRetryCount + (event.reason.retryBudgetConsumes ? 1 : 0)
        RecordingDiagnostics.shared.recordFailureEvent(
            event,
            retryBudgetBefore: retryBudgetBefore,
            retryBudgetAfter: retryBudgetAfter,
            budgetConsumed: event.reason.retryBudgetConsumes,
            coalescedIntoExistingRecovery: false
        )
        AppDiagnostics.error(
            .appState,
            "Recording auto-stopped context={\(RecordingDiagnostics.shared.contextSnapshot())} session=\(sessionID) reason=\(event.reason.rawValue) reasonCategory=\(event.reason.reasonCategory) isBluetoothRelated=\(AppDiagnostics.boolLabel(event.reason.isBluetoothRelated)) isRecoverable=\(AppDiagnostics.boolLabel(event.reason.isRecoverable)) retryBudgetConsumes=\(AppDiagnostics.boolLabel(event.reason.retryBudgetConsumes)) userMessage=\(AppDiagnostics.quoted(event.userMessage, limit: 400)) retryCountBeforeIncrement=\(autoRetryCount) capture={\(event.captureSnapshot.snapshot)} snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        autoRetryCount = retryBudgetAfter

        if autoRetryCount > 3 {
            RecordingDiagnostics.shared.recordRetryDecision(
                .retryBudgetExceeded,
                detail: "reason=\(event.reason.rawValue) retryBudgetBefore=\(retryBudgetBefore) retryBudgetAfter=\(autoRetryCount) recoveryCycle=\(recoveryCycleID)"
            )
            AppDiagnostics.error(
                .appState,
                "Exceeded max retries context={\(RecordingDiagnostics.shared.contextSnapshot())} retryCount=\(self.autoRetryCount) snapshot={\(stateSnapshot())} availableDevices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
            )
            recordingRecoveryPending = false
            autoRetryTask?.cancel()
            currentState = .idle
            statusMessage = "Recording failed"
            errorMessage = "Microphone unavailable. Try disconnecting and reconnecting your headphones."
            recordingIndicator.hide()
            RecordingDiagnostics.shared.dumpBreadcrumbs(reason: "retry_budget_exhausted")
            RecordingDiagnostics.shared.emitIncidentSummary(outcome: "failed", failureReason: .retryBudgetExhausted)
            activeRecoveryCycleID = nil
            return
        }

        let routeStabilityRequiredMs = event.reason.isBluetoothRelated ? 1500 : 600
        let delaySeconds = Self.delayBeforeReconnectAttempt(reason: event.reason, attempt: autoRetryCount)
        let baseDelayMs = Int(delaySeconds * 1000)

        RecordingDiagnostics.shared.recordRetryDecision(
            .retryScheduled,
            detail: "reason=\(event.reason.rawValue) retryBudgetBefore=\(retryBudgetBefore) retryBudgetAfter=\(autoRetryCount) baseDelayMs=\(baseDelayMs) extraDelayForBluetoothMs=\(event.reason.isBluetoothRelated ? baseDelayMs : 0) extraDelayForRecentRouteChurnMs=0 finalDelayMs=\(baseDelayMs) decisionRuleVersion=2 recoveryCycle=\(recoveryCycleID)"
        )
        AppDiagnostics.warning(
            .appState,
            "Scheduling retry on current route context={\(RecordingDiagnostics.shared.contextSnapshot())} delay=\(String(format: "%.1f", delaySeconds))s retryCount=\(autoRetryCount) reason=\(event.reason.rawValue) userMessage=\(AppDiagnostics.quoted(event.userMessage, limit: 400)) snapshot={\(stateSnapshot())}"
        )
        currentState = .idle
        statusMessage = "Reconnecting..."
        recordingIndicator.showReconnecting()
        RecordingDiagnostics.shared.setRecoveringState()

        recordingRecoveryPending = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard let self else { return }
            guard !Task.isCancelled, self.currentState == .idle else {
                self.recordingRecoveryPending = false
                RecordingDiagnostics.shared.recordRetryDecision(
                    .retryAbortedDueToStateChange,
                    detail: "reason=\(event.reason.rawValue) recoveryCycle=\(recoveryCycleID)"
                )
                AppDiagnostics.info(.appState, "Route retry cancelled before execution context={\(RecordingDiagnostics.shared.contextSnapshot())}")
                return
            }
            self.recordRetryPreflightRouteSummary(
                reason: event.reason,
                recoveryCycleID: recoveryCycleID,
                requiredStableWindowMs: routeStabilityRequiredMs
            )
            await self.retryStartRecording()
        }
    }

    /// Longer delay after route / HFP churn (similar to what a reboot indirectly provides: time to settle).
    private static func delayBeforeReconnectAttempt(reason: RecordingFailureReason, attempt: Int) -> TimeInterval {
        if attempt == 1 {
            return reason.isBluetoothRelated ? 2.5 : 1.0
        }
        return reason.isBluetoothRelated ? 2.0 : 1.5
    }

    private func retryStartRecording() async {
        guard transcriptionEngine.isModelLoaded else { return }
        refreshPermissionStates(source: "retryStartRecording")
        guard microphonePermissionStatus.isAuthorized else {
            currentState = .idle
            statusMessage = "Microphone access required"
            errorMessage = microphonePermissionStatus == .restricted
                ? "Microphone access is restricted by macOS or device policy."
                : "Settings → search \"Privacy\" → Microphone → toggle DICTATR on"
            recordingIndicator.hide()
            RecordingDiagnostics.shared.recordRetryDecision(
                .retryAbortedDueToPermissionChange,
                detail: "status=\(microphonePermissionStatus.rawValue) recoveryCycle=\(activeRecoveryCycleID ?? "none")"
            )
            AppDiagnostics.warning(
                .appState,
                "retryStartRecording blocked because microphone access is unavailable context={\(RecordingDiagnostics.shared.contextSnapshot())} status=\(microphonePermissionStatus.rawValue)"
            )
            return
        }
        RecordingDiagnostics.shared.recordRetryDecision(
            .retryStarted,
            detail: "retryCount=\(autoRetryCount) recoveryCycle=\(activeRecoveryCycleID ?? "none") lastObservedRouteChangeMsAgo=\(RecordingDiagnostics.shared.millisecondsSinceLastRouteChange())"
        )
        AppDiagnostics.info(
            .appState,
            "retryStartRecording context={\(RecordingDiagnostics.shared.contextSnapshot())} retryCount=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )

        do {
            let url = try await audioRecorder.startRecording(
                metadata: RecordingAttemptMetadata(
                    trigger: "retry_scheduler",
                    recoveryCycleID: activeRecoveryCycleID,
                    retryAttempt: autoRetryCount
                )
            )
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
            recordingIndicator.show(audioRecorder: audioRecorder)
            RecordingDiagnostics.shared.recordRetryDecision(
                .retrySucceeded,
                detail: "retryCount=\(autoRetryCount) recoveryCycle=\(activeRecoveryCycleID ?? "none")"
            )
            RecordingDiagnostics.shared.completeRecoveryCycleIfNeeded()
            activeRecoveryCycleID = nil
            recordingRecoveryPending = false
            AppDiagnostics.info(
                .appState,
                "retry succeeded context={\(RecordingDiagnostics.shared.contextSnapshot())} session=\(audioRecorder.recordingSessionID ?? "none") file=\(url.lastPathComponent) snapshot={\(stateSnapshot())}"
            )
        } catch {
            recordingRecoveryPending = false
            let reason = RecordingFailureReason.from(error: error)
            RecordingDiagnostics.shared.recordRetryDecision(
                .retryFailed,
                detail: "reason=\(reason.rawValue) retryCount=\(autoRetryCount) recoveryCycle=\(activeRecoveryCycleID ?? "none")"
            )
            AppDiagnostics.error(
                .appState,
                "retry failed context={\(RecordingDiagnostics.shared.contextSnapshot())} reason=\(reason.rawValue) error=\(error.localizedDescription) retryCount=\(autoRetryCount) snapshot={\(stateSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
            )
            handleRecordingFailure(
                event: RecordingFailureEvent(
                    reason: reason,
                    userMessage: reason.defaultUserMessage,
                    framesWritten: 0,
                    droppedFrames: 0,
                    routeState: AudioDeviceDiagnostics.currentRouteState(),
                    captureSnapshot: CaptureCadenceSnapshot(
                        firstTapCallbackMs: nil,
                        tapCallbackCount: 0,
                        lastTapCallbackMsAgo: nil,
                        buffersReceived: 0,
                        buffersConverted: 0,
                        buffersDropped: 0,
                        framesReceivedRaw: 0,
                        framesConverted: 0,
                        framesWritten: 0,
                        largestInputBufferFrames: 0,
                        smallestInputBufferFrames: 0,
                        avgCallbackIntervalMs: nil,
                        timeSinceFirstTapMs: nil,
                        timeSinceLastTapMs: nil,
                        timeSinceLastFrameWriteMs: nil,
                        captureState: "never_started",
                        firstNonZeroWriteMs: nil
                    ),
                    detail: "retry start failed error=\(error.localizedDescription)"
                )
            )
        }
    }

    private func recordRetryPreflightRouteSummary(
        reason: RecordingFailureReason,
        recoveryCycleID: String,
        requiredStableWindowMs: Int
    ) {
        let lastObservedRouteChangeMsAgo = RecordingDiagnostics.shared.millisecondsSinceLastRouteChange()
        let routeState = AudioDeviceDiagnostics.currentRouteState()
        RecordingDiagnostics.shared.recordRetryDecision(
            .retryWaitCompleted,
            detail: "reason=\(reason.rawValue) route_considered_stable=\(AppDiagnostics.boolLabel(lastObservedRouteChangeMsAgo >= requiredStableWindowMs)) stableWindowMs=\(requiredStableWindowMs) lastObservedRouteChangeMsAgo=\(lastObservedRouteChangeMsAgo) routeAgeIsAdvisoryOnly=yes graphReadyDeterminedByEngineStart=yes recoveryCycle=\(recoveryCycleID) routeFingerprint=\(routeState.fingerprint)"
        )
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
            "recording stopped context={\(RecordingDiagnostics.shared.contextSnapshot())} session=\(sessionID) duration=\(String(format: "%.3f", result.duration))s frames=\(result.framesWritten) capture={\(result.forensics.captureSnapshot.snapshot)} file=\(result.url.lastPathComponent) routeAtStopFingerprint=\(result.forensics.routeAtStopFingerprint) routeChangedDuringSession=\(AppDiagnostics.boolLabel(result.forensics.routeChangedDuringSession)) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(result.forensics.captureStalledDuringSession)) snapshot={\(stateSnapshot())}"
        )

        let signalStats = Self.analyzeAudioSignal(at: result.url)
        if let signalStats {
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

        let transcriptionStartRoute = AudioDeviceDiagnostics.currentRouteState()
        let silentDespiteFrames = result.framesWritten > 0 && (signalStats?.sampleCount ?? 0) > 0 &&
            ((signalStats?.rms ?? 0) <= 0.000_001 && (signalStats?.peak ?? 0) <= 0.000_001)
        AppDiagnostics.info(
            .appState,
            "recording forensic summary context={\(RecordingDiagnostics.shared.contextSnapshot())} session=\(sessionID) capture={\(result.forensics.captureSnapshot.snapshot)} routeAtStartFingerprint=\(result.forensics.routeAtStartFingerprint) routeAtStopFingerprint=\(result.forensics.routeAtStopFingerprint) routeAtTranscriptionStartFingerprint=\(transcriptionStartRoute.fingerprint) routeChangedDuringSession=\(AppDiagnostics.boolLabel(result.forensics.routeChangedDuringSession)) routeChangedBeforeTranscription=\(AppDiagnostics.boolLabel(result.forensics.routeAtStopFingerprint != transcriptionStartRoute.fingerprint)) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(result.forensics.captureStalledDuringSession)) silentDespiteNonZeroFrames=\(AppDiagnostics.boolLabel(silentDespiteFrames)) lastKnownInput={\(result.forensics.lastKnownInputSnapshot)} lastKnownOutput={\(result.forensics.lastKnownOutputSnapshot)} routeAtStop={\(result.forensics.routeAtStopSnapshot)} routeAtTranscriptionStart={\(transcriptionStartRoute.routeSnapshot)}"
        )

        // Cancel any lingering previous transcription task
        transcriptionTask?.cancel()

        transcriptionTask = Task { [weak self] in
            do {
                guard let self else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }
                let transcription = try await self.transcriptionEngine.transcribe(audioURL: result.url)
                AppDiagnostics.info(
                    .appState,
                    "transcription returned session=\(sessionID) duration=\(String(format: "%.3f", result.duration))s chars=\(transcription.text.count) text=\(AppDiagnostics.quoted(transcription.text, limit: 1200)) rawText=\(AppDiagnostics.quoted(transcription.rawText, limit: 1200)) file=\(result.url.lastPathComponent) snapshot={\(self.stateSnapshot())}"
                )

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                if transcription.text.isEmpty {
                    let emptyMessage =
                        "transcription returned empty text session=\(sessionID) duration=\(String(format: "%.3f", result.duration))s chars=0 text=\(AppDiagnostics.quoted(transcription.text, limit: 1200)) rawText=\(AppDiagnostics.quoted(transcription.rawText, limit: 1200)) file=\(result.url.lastPathComponent) snapshot={\(self.stateSnapshot())}"

                    if result.duration >= 5.0 {
                        AppDiagnostics.error(.appState, emptyMessage)
                    } else {
                        AppDiagnostics.info(.appState, emptyMessage)
                    }
                    self.recordingIndicator.hide()
                    if Self.shouldTreatAsCaptureFailure(
                        duration: result.duration,
                        signalStats: signalStats,
                        containsOnlyPlaceholderTokens: transcription.containsOnlyPlaceholderTokens
                    ) {
                        self.statusMessage = "Microphone capture failed"
                        self.errorMessage = "DICTATR recorded silence. Check System Settings → Privacy & Security → Microphone and confirm DICTATR is allowed to record."
                    } else {
                        self.statusMessage = "No speech detected"
                    }
                    self.currentState = .idle
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                AppDiagnostics.info(
                    .appState,
                    "transcription complete session=\(sessionID) duration=\(String(format: "%.3f", result.duration))s chars=\(transcription.text.count) text=\(AppDiagnostics.quoted(transcription.text, limit: 1200)) rawText=\(AppDiagnostics.quoted(transcription.rawText, limit: 1200)) snapshot={\(self.stateSnapshot())}"
                )
                self.lastTranscription = transcription.text

                // Paste to active app
                let pasteResult = await PasteManager.paste(text: transcription.text, autoPaste: self.autoPasteEnabled)
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
                            text: transcription.text,
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
    static func shouldTreatAsCaptureFailure(
        duration: TimeInterval,
        signalStats: (rms: Float, peak: Float, sampleCount: Int)?,
        containsOnlyPlaceholderTokens: Bool
    ) -> Bool {
        let hasZeroSignal = signalStats.map { $0.sampleCount > 0 && $0.rms <= 0.000_001 && $0.peak <= 0.000_001 } ?? false

        if containsOnlyPlaceholderTokens && duration >= 5.0 {
            return true
        }

        return hasZeroSignal && duration >= 1.0
    }

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
