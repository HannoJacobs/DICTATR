import Foundation

enum WhisperModelChoice: String, CaseIterable, Equatable, Sendable {
    case smallEnglish = "openai_whisper-small.en"
    case largeV3_626MB = "openai_whisper-large-v3-v20240930_626MB"

    static let defaultsKey = "selectedWhisperModelVariant"
    static let defaultChoice = WhisperModelChoice.smallEnglish

    var pickerLabel: String {
        switch self {
        case .smallEnglish:
            return "Whisper Small (English) — Default"
        case .largeV3_626MB:
            return "Whisper Large V3"
        }
    }

    var detailText: String {
        switch self {
        case .smallEnglish:
            return "Default English-only model. Faster startup and lower compile cost on this Mac class."
        case .largeV3_626MB:
            return "~626 MB download; first use may take several minutes to compile."
        }
    }

    static func resolve(stored: String?) -> WhisperModelChoice {
        guard let stored, !stored.isEmpty else {
            return .defaultChoice
        }

        guard let choice = WhisperModelChoice(rawValue: stored) else {
            return .defaultChoice
        }

        return choice
    }

    static func read(from defaults: UserDefaults = .standard) -> WhisperModelChoice {
        resolve(stored: defaults.string(forKey: defaultsKey))
    }

    static func write(_ choice: WhisperModelChoice, to defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: defaultsKey)
    }
}

enum ModelSwitchBlockedReason: String, Equatable, Sendable {
    case recording
    case transcribing
    case modelLoading
    case modelSwitching
    case localTranscription
    case httpTranscription
    case recordingStart
    case recordingRecovery

    var userFacingMessage: String {
        switch self {
        case .recording:
            return "Finish or stop recording before changing the model."
        case .transcribing:
            return "Wait for transcription to finish before changing the model."
        case .modelLoading:
            return "Wait for the current model load to finish before changing the model."
        case .modelSwitching:
            return "A model switch is already in progress."
        case .localTranscription:
            return "Wait for the current transcription to finish before changing the model."
        case .httpTranscription:
            return "Wait for the HTTP transcription request to finish before changing the model."
        case .recordingStart:
            return "Wait for recording to finish starting before changing the model."
        case .recordingRecovery:
            return "Wait for microphone recovery to finish before changing the model."
        }
    }
}

enum ModelSwitchPolicy: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        var dictationState: DictationState
        var isModelLoading: Bool
        var hasModelLoadTask: Bool
        var isModelSwitching: Bool
        var hasInFlightLocalTranscription: Bool
        var inFlightHTTPTranscriptions: Int
        var recordingStartInProgress: Bool
        var isRecorderRecording: Bool
        var recordingRecoveryPending: Bool
    }

    static func canEditSelection(_ snapshot: Snapshot) -> Bool {
        blockedReason(snapshot) == nil
    }

    static func canStartRecording(_ snapshot: Snapshot) -> Bool {
        !snapshot.isModelSwitching &&
            !snapshot.isModelLoading &&
            !snapshot.hasModelLoadTask
    }

    static func blockedReason(_ snapshot: Snapshot) -> ModelSwitchBlockedReason? {
        if snapshot.isModelSwitching {
            return .modelSwitching
        }
        if snapshot.isModelLoading || snapshot.hasModelLoadTask {
            return .modelLoading
        }
        if snapshot.dictationState == .recording || snapshot.isRecorderRecording {
            return .recording
        }
        if snapshot.dictationState == .transcribing {
            return .transcribing
        }
        if snapshot.hasInFlightLocalTranscription {
            return .localTranscription
        }
        if snapshot.inFlightHTTPTranscriptions > 0 {
            return .httpTranscription
        }
        if snapshot.recordingStartInProgress {
            return .recordingStart
        }
        if snapshot.recordingRecoveryPending {
            return .recordingRecovery
        }
        if snapshot.dictationState != .idle {
            return .transcribing
        }
        return nil
    }

    static func shouldReload(selected: WhisperModelChoice, activeVariant: String?) -> Bool {
        activeVariant != selected.rawValue
    }
}
