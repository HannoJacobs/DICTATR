import AppKit
import Foundation
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
        return count > 0 ? count : 100
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

        // Load model in background (store task for cancellation)
        modelLoadTask = Task { [weak self] in
            await self?.loadModel()
        }
    }

    deinit {
        modelLoadTask?.cancel()
        transcriptionTask?.cancel()
    }

    func loadModel() async {
        do {
            statusMessage = "Loading model..."
            try await transcriptionEngine.loadModel()
            if Task.isCancelled { return }
            statusMessage = "Ready"
        } catch {
            if Task.isCancelled { return }
            statusMessage = "Model load failed"
            let modelError = "Model load failed: \(error.localizedDescription)"
            if let existing = errorMessage {
                errorMessage = "\(existing)\n\(modelError)"
            } else {
                errorMessage = modelError
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
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let result = audioRecorder.stopRecording() else {
            // Reset to idle if stop fails — prevents state stuck at .recording
            currentState = .idle
            statusMessage = "Recording failed"
            return
        }

        // Skip transcription for empty or trivially short recordings
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        if result.duration < 0.3 || fileSize < 1000 {
            statusMessage = "Recording too short"
            currentState = .idle
            try? FileManager.default.removeItem(at: result.url)
            return
        }

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

                self.errorMessage = nil
                self.statusMessage = "Done"
                self.currentState = .idle

            } catch {
                // Clean up temp audio file on failure
                try? FileManager.default.removeItem(at: result.url)
                guard let self else { return }
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
