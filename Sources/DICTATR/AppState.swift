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
import SwiftUI

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
}

@Observable
@MainActor
final class AppState {
    var currentState: DictationState = .idle
    var lastTranscription: String?
    var statusMessage: String = "Ready"
    var errorMessage: String?

    // Stored properties with didSet so @Observable tracks changes correctly.
    // Computed properties are NOT instrumented by @Observable, so using them
    // would cause SwiftUI views to never re-render on value changes.
    var autoPasteEnabled: Bool = UserDefaults.standard.bool(forKey: "autoPasteEnabled") {
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
                self.statusMessage = "Downloading model..."
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
            _ = try audioRecorder.startRecording()
            NSSound(named: .init("Tink"))?.play()
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
            recordingIndicator.show(audioRecorder: audioRecorder)
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndTranscribe() {
        NSSound(named: .init("Pop"))?.play()
        guard let result = audioRecorder.stopRecording() else {
            // Reset to idle if stop fails — prevents state stuck at .recording
            recordingIndicator.hide()
            currentState = .idle
            statusMessage = "Recording failed"
            return
        }

        // Skip transcription for empty or trivially short recordings
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        if result.duration < 0.3 || fileSize < 1000 {
            recordingIndicator.hide()
            statusMessage = "Recording too short"
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
                    self.recordingIndicator.hide()
                    self.statusMessage = "No speech detected"
                    self.currentState = .idle
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }

                self.lastTranscription = text

                // Paste to active app
                await PasteManager.paste(text: text, autoPaste: self.autoPasteEnabled)

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

                self.recordingIndicator.showDone()
                NSSound(named: .init("Glass"))?.play()
                self.errorMessage = nil
                self.statusMessage = "Done"
                self.currentState = .idle

            } catch {
                // Clean up temp audio file on failure
                try? FileManager.default.removeItem(at: result.url)
                guard let self else { return }
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
