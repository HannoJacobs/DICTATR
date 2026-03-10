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
//   3. DICTATRApp shows ModelDownloadView while !isModelLoaded
//   4. When isModelLoaded becomes true → MenuBarView shown, hotkey active
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

    var currentState: DictationState = .idle
    var lastTranscription: String?
    var statusMessage: String = "Ready"
    var errorMessage: String?

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
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }

    var retentionCount: Int = {
        let count = UserDefaults.standard.integer(forKey: "retentionCount")
        return count > 0 ? count : 10
    }() {
        didSet {
            retentionCount = max(1, retentionCount)
            UserDefaults.standard.set(retentionCount, forKey: "retentionCount")
        }
    }

    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    let audioRecorder = AudioRecorder()
    let transcriptionEngine = TranscriptionEngine()
    let databaseManager: DatabaseManager?

    private var hotkeyManager: HotkeyManager?
    private var modelLoadTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var autoRetryTask: Task<Void, Never>?
    private var autoRetryCount = 0
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
            self.databaseManager = nil
            self.errorMessage = "History unavailable: database failed to load."
        }

        // Wire up auto-stop callback from AudioRecorder (watchdog timeout, engine failure)
        audioRecorder.onRecordingFailed = { [weak self] message in
            self?.handleRecordingFailure(message: message)
        }

        // Register hotkey — dispatch to MainActor since callback thread is unspecified
        hotkeyManager = HotkeyManager { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

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
                self.statusMessage = "Loading model..."
                try await self.transcriptionEngine.loadModel()
                if Task.isCancelled { return }
                self.statusMessage = "Ready"
                self.errorMessage = nil
            } catch {
                if Task.isCancelled { return }
                self.statusMessage = "Model load failed"
                self.errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func toggleRecording() {
        switch currentState {
        case .idle:
            autoRetryCount = 0
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
            errorMessage = "Model is still loading. Please wait."
            return
        }

        do {
            let url = try audioRecorder.startRecording()
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
            NSSound(named: .init("Tink"))?.play()
            recordingIndicator.show(audioRecorder: audioRecorder)
            Self.logger.info("Recording started → \(url.lastPathComponent)")
        } catch {
            currentState = .idle
            statusMessage = "Ready"
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            Self.logger.error("Recording failed to start: \(error.localizedDescription)")
        }
    }

    private static let maxAutoRetries = 4
    private static let retryDelays: [Double] = [1.5, 2.5, 3.5, 4.0]

    private func handleRecordingFailure(message: String) {
        Self.logger.error("Recording auto-stopped: \(message)")

        // Auto-retry with escalating delays for Bluetooth profile switches, which can
        // take 5-10+ seconds to settle after a call. Each retry creates a fresh engine.
        autoRetryCount += 1
        if autoRetryCount <= Self.maxAutoRetries {
            let delay = Self.retryDelays[min(autoRetryCount - 1, Self.retryDelays.count - 1)]
            Self.logger.info("Auto-retrying recording (attempt \(self.autoRetryCount)/\(Self.maxAutoRetries), delay \(delay)s)...")
            currentState = .idle
            statusMessage = "Reconnecting..."
            recordingIndicator.showReconnecting()

            autoRetryTask?.cancel()
            autoRetryTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, currentState == .idle else { return }
                self.startRecording()
            }
        } else {
            recordingIndicator.hide()
            currentState = .idle
            statusMessage = "Recording failed"
            errorMessage = message
        }
    }

    private func stopRecordingAndTranscribe() {
        NSSound(named: .init("Pop"))?.play()
        guard let result = audioRecorder.stopRecording() else {
            // Reset to idle if stop fails — force-reset ensures full cleanup
            Self.logger.error("stopRecording() returned nil — force-resetting recorder")
            audioRecorder.forceReset()
            recordingIndicator.hide()
            currentState = .idle
            statusMessage = "Recording failed"
            return
        }

        Self.logger.info("Recording stopped: \(String(format: "%.1f", result.duration))s, \(result.framesWritten) frames, file=\(result.url.lastPathComponent)")

        // Skip transcription for empty or trivially short recordings
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        if result.duration < 0.3 || fileSize < 1000 {
            Self.logger.info("Recording too short (duration=\(String(format: "%.2f", result.duration))s, fileSize=\(fileSize)B) — skipping transcription")
            recordingIndicator.hide()
            statusMessage = "Recording too short"
            currentState = .idle
            try? FileManager.default.removeItem(at: result.url)
            return
        }

        // Detect hardware/driver issues where recording ran but no audio was captured
        if result.framesWritten < 800 { // ~50ms at 16kHz
            Self.logger.warning("No audio captured: \(result.framesWritten) frames written in \(String(format: "%.1f", result.duration))s — likely mic/Bluetooth issue")
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

                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                if text.isEmpty {
                    Self.logger.info("Transcription returned empty text — no speech detected")
                    self.recordingIndicator.hide()
                    self.statusMessage = "No speech detected"
                    self.currentState = .idle
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                Self.logger.info("Transcription complete: \(text.count) chars")
                self.lastTranscription = text

                // Paste to active app
                let pasteResult = await PasteManager.paste(text: text, autoPaste: self.autoPasteEnabled)
                Self.logger.info("Paste result: \(String(describing: pasteResult))")

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
                Self.logger.error("Transcription failed: \(error.localizedDescription)")
                self.recordingIndicator.hide()
                self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                self.statusMessage = "Error"
                self.currentState = .idle
            }
        }
    }

    func copyToClipboard(_ text: String) {
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
