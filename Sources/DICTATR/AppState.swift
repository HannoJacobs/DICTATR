import AppKit
import Foundation
import SwiftUI

enum DictationState: Equatable {
    case idle
    case recording
    case transcribing
}

@Observable
final class AppState {
    var currentState: DictationState = .idle
    var lastTranscription: String?
    var statusMessage: String = "Ready"
    var errorMessage: String?

    var autoPasteEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoPasteEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "autoPasteEnabled") }
    }

    var retentionCount: Int {
        get {
            let count = UserDefaults.standard.integer(forKey: "retentionCount")
            return count > 0 ? count : 100
        }
        set { UserDefaults.standard.set(newValue, forKey: "retentionCount") }
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    let audioRecorder = AudioRecorder()
    let transcriptionEngine = TranscriptionEngine()
    let databaseManager: DatabaseManager?

    private var hotkeyManager: HotkeyManager?
    private var currentAudioURL: URL?

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
        // Initialize database, fail gracefully
        do {
            self.databaseManager = try DatabaseManager()
        } catch {
            print("Failed to initialize database: \(error)")
            self.databaseManager = nil
        }

        // Set default for auto-paste if not set
        if !UserDefaults.standard.contains(key: "autoPasteEnabled") {
            UserDefaults.standard.set(true, forKey: "autoPasteEnabled")
        }

        // Register hotkey
        hotkeyManager = HotkeyManager { [weak self] in
            self?.toggleRecording()
        }

        // Load model in background
        Task {
            await loadModel()
        }
    }

    func loadModel() async {
        do {
            statusMessage = "Loading model..."
            try await transcriptionEngine.loadModel()
            statusMessage = "Ready"
        } catch {
            statusMessage = "Model load failed"
            errorMessage = error.localizedDescription
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
            currentAudioURL = try audioRecorder.startRecording()
            currentState = .recording
            statusMessage = "Recording..."
            errorMessage = nil
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecordingAndTranscribe() {
        guard let result = audioRecorder.stopRecording() else { return }

        currentState = .transcribing
        statusMessage = "Transcribing..."

        Task { @MainActor in
            do {
                let text = try await transcriptionEngine.transcribe(audioURL: result.url)

                if text.isEmpty {
                    statusMessage = "No speech detected"
                    currentState = .idle
                    return
                }

                lastTranscription = text

                // Paste to active app
                await PasteManager.paste(text: text, autoPaste: autoPasteEnabled)

                // Save to database
                if let db = databaseManager {
                    var record = DictationRecord(
                        text: text,
                        duration: result.duration,
                        audioFilePath: result.url.path,
                        createdAt: Date()
                    )
                    try db.save(&record)
                    try db.deleteOld(keepLast: retentionCount)
                }

                statusMessage = "Done"
                currentState = .idle

            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                statusMessage = "Error"
                currentState = .idle
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
