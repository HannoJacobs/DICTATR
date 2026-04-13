import Foundation

enum RecordingFailureReason: String {
    case engineConfigurationChangedEngineStopped = "engine_configuration_changed_engine_stopped"
    case engineStartFailed = "engine_start_failed"
    case inputFormatInvalid = "input_format_invalid"
    case converterCreationFailed = "converter_creation_failed"
    case noAudioWatchdogTimeout = "no_audio_watchdog_timeout"
    case captureStalled = "capture_stalled"
    case routeChangedDuringStart = "route_changed_during_start"
    case bluetoothHFPRenegotiation = "bluetooth_hfp_renegotiation"
    case retryBudgetExhausted = "retry_budget_exhausted"
    case duplicateFailureWhileRecoveryPending = "duplicate_failure_while_recovery_pending"
    case manualStopDuringRecovery = "manual_stop_during_recovery"
    case microphonePermissionUnavailable = "microphone_permission_unavailable"
    case unknown = "unknown"

    var reasonCategory: String {
        switch self {
        case .engineConfigurationChangedEngineStopped, .engineStartFailed,
             .inputFormatInvalid, .converterCreationFailed:
            return "engine"
        case .noAudioWatchdogTimeout, .captureStalled:
            return "capture"
        case .routeChangedDuringStart, .bluetoothHFPRenegotiation:
            return "route"
        case .retryBudgetExhausted, .duplicateFailureWhileRecoveryPending, .manualStopDuringRecovery:
            return "recovery"
        case .microphonePermissionUnavailable:
            return "permission"
        case .unknown:
            return "unknown"
        }
    }

    var isBluetoothRelated: Bool {
        switch self {
        case .engineConfigurationChangedEngineStopped, .routeChangedDuringStart, .bluetoothHFPRenegotiation:
            return true
        default:
            return false
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .engineConfigurationChangedEngineStopped, .routeChangedDuringStart, .bluetoothHFPRenegotiation,
             .noAudioWatchdogTimeout, .captureStalled:
            return true
        case .engineStartFailed, .inputFormatInvalid, .converterCreationFailed,
             .retryBudgetExhausted, .duplicateFailureWhileRecoveryPending,
             .manualStopDuringRecovery, .microphonePermissionUnavailable, .unknown:
            return false
        }
    }

    var retryBudgetConsumes: Bool {
        switch self {
        case .duplicateFailureWhileRecoveryPending, .manualStopDuringRecovery:
            return false
        default:
            return true
        }
    }

    var defaultUserMessage: String {
        switch self {
        case .engineConfigurationChangedEngineStopped, .routeChangedDuringStart, .bluetoothHFPRenegotiation:
            return "Audio device changed. Reconnecting..."
        case .engineStartFailed:
            return "Failed to start recording."
        case .inputFormatInvalid:
            return "Input format is not ready yet."
        case .converterCreationFailed:
            return "Failed to create audio converter."
        case .noAudioWatchdogTimeout:
            return "No audio captured after 5 seconds. Check your microphone or try reconnecting your headphones."
        case .captureStalled:
            return "Audio capture stalled. Reconnecting..."
        case .retryBudgetExhausted:
            return "Microphone unavailable. Try disconnecting and reconnecting your headphones."
        case .duplicateFailureWhileRecoveryPending:
            return "Microphone recovery is already in progress."
        case .manualStopDuringRecovery:
            return "Recording recovery was interrupted."
        case .microphonePermissionUnavailable:
            return "Microphone access is unavailable."
        case .unknown:
            return "Recording failed."
        }
    }

    var recommendedAction: String {
        switch self {
        case .engineConfigurationChangedEngineStopped, .bluetoothHFPRenegotiation, .retryBudgetExhausted:
            return "reconnect_headphones"
        case .routeChangedDuringStart:
            return "wait_for_bluetooth_route_to_stabilize"
        case .noAudioWatchdogTimeout, .captureStalled:
            return "switch_to_built_in_mic"
        case .microphonePermissionUnavailable:
            return "inspect_permissions"
        case .engineStartFailed, .inputFormatInvalid, .converterCreationFailed, .unknown:
            return "report_bug_with_log_bundle"
        case .duplicateFailureWhileRecoveryPending, .manualStopDuringRecovery:
            return "wait_for_current_recovery_cycle"
        }
    }

    static func from(error: Error) -> RecordingFailureReason {
        switch error {
        case AudioRecorderError.formatCreationFailed:
            return .inputFormatInvalid
        case AudioRecorderError.converterCreationFailed:
            return .converterCreationFailed
        default:
            return .engineStartFailed
        }
    }
}

enum RecoveryDecision: String {
    case retryStarted = "retry_started"
    case retryScheduled = "retry_scheduled"
    case retryWaitStarted = "reconnect_wait_started"
    case retryWaitExtendedDueToRouteChange = "reconnect_wait_extended_due_to_route_change"
    case retryWaitCompleted = "reconnect_wait_completed"
    case retrySucceeded = "retry_succeeded"
    case retryFailed = "retry_failed"
    case retryAbortedDueToStateChange = "retry_aborted_due_to_state_change"
    case retryAbortedDueToPermissionChange = "retry_aborted_due_to_permission_change"
    case retryAbortedDueToRouteUnstable = "retry_aborted_due_to_route_unstable"
    case retryBudgetExceeded = "retry_budget_exceeded"
    case duplicateFailureCoalesced = "duplicate_failure_coalesced"
}

enum BluetoothModeGuess: String {
    case a2dp
    case hfp
    case mixed
    case unknown
}

struct BluetoothModeAssessment {
    let mode: BluetoothModeGuess
    let outputNominalHz: String
    let inputNominalHz: String
    let confidence: String
    let reason: String
}

struct RecordingAttemptMetadata {
    let trigger: String
    let recoveryCycleID: String?
    let retryAttempt: Int

    static let userHotkey = RecordingAttemptMetadata(trigger: "user_hotkey", recoveryCycleID: nil, retryAttempt: 0)
}

struct RecordingAttemptContext {
    let recordingSessionID: String
    let attemptID: String
    let engineInstanceID: String
}

struct CaptureCadenceSnapshot {
    let firstTapCallbackMs: Int?
    let tapCallbackCount: Int64
    let lastTapCallbackMsAgo: Int?
    let buffersReceived: Int64
    let buffersConverted: Int64
    let buffersDropped: Int64
    let framesReceivedRaw: Int64
    let framesConverted: Int64
    let framesWritten: Int64
    let largestInputBufferFrames: Int
    let smallestInputBufferFrames: Int
    let avgCallbackIntervalMs: Int?
    let timeSinceFirstTapMs: Int?
    let timeSinceLastTapMs: Int?
    let timeSinceLastFrameWriteMs: Int?
    let captureState: String
    let firstNonZeroWriteMs: Int?

    var snapshot: String {
        [
            "captureState=\(captureState)",
            "firstTapCallbackMs=\(firstTapCallbackMs.map(String.init) ?? "nil")",
            "firstNonZeroWriteMs=\(firstNonZeroWriteMs.map(String.init) ?? "nil")",
            "tapCallbackCount=\(tapCallbackCount)",
            "lastTapCallbackMsAgo=\(lastTapCallbackMsAgo.map(String.init) ?? "nil")",
            "buffersReceived=\(buffersReceived)",
            "buffersConverted=\(buffersConverted)",
            "buffersDropped=\(buffersDropped)",
            "framesReceivedRaw=\(framesReceivedRaw)",
            "framesConverted=\(framesConverted)",
            "framesWritten=\(framesWritten)",
            "largestInputBufferFrames=\(largestInputBufferFrames)",
            "smallestInputBufferFrames=\(smallestInputBufferFrames)",
            "avgCallbackIntervalMs=\(avgCallbackIntervalMs.map(String.init) ?? "nil")",
            "timeSinceFirstTapMs=\(timeSinceFirstTapMs.map(String.init) ?? "nil")",
            "timeSinceLastTapMs=\(timeSinceLastTapMs.map(String.init) ?? "nil")",
            "timeSinceLastFrameWriteMs=\(timeSinceLastFrameWriteMs.map(String.init) ?? "nil")"
        ].joined(separator: " ")
    }
}

struct RecordingFailureEvent {
    let reason: RecordingFailureReason
    let userMessage: String
    let framesWritten: Int64
    let droppedFrames: Int64
    let routeState: AudioDeviceDiagnostics.RouteState
    let captureSnapshot: CaptureCadenceSnapshot
    let detail: String
}

struct DiagnosticsBreadcrumb {
    let timestamp: Date
    let category: String
    let event: String
    let context: String
    let detail: String

    var snapshot: String {
        let timestamp = ISO8601DateFormatter.string(
            from: timestamp,
            timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        return "timestamp=\(timestamp) category=\(category) event=\(event) context={\(context)} detail={\(detail)}"
    }
}

struct RouteObservation {
    let routeEpoch: Int
    let previousFingerprint: String
    let currentFingerprint: String
    let changedFields: [String]
    let stableForMsBeforeChange: Int
    let timeSinceAttemptStartMs: Int?
    let timeSinceEngineStartMs: Int?
    let bluetoothModeAssessment: BluetoothModeAssessment
    let previousBluetoothMode: BluetoothModeGuess
    let currentBluetoothMode: BluetoothModeGuess
    let aggregateDeviceID: String
    let lastObservedRouteChangeMsAgo: Int
    let effectiveChange: Bool
}

struct FailureIncidentSummary {
    let incidentID: String
    let outcome: String
    let failureReason: RecordingFailureReason
    let recordingSessionID: String
    let recoveryCycleID: String
    let attemptCount: Int
    let routeEpochStart: Int
    let routeEpochEnd: Int
    let routeChangedCount: Int
    let bluetoothModeTransitions: [String]
    let routeStableWindowsMs: [Int]
    let firstFailureAtMs: Int?
    let finalFailureAtMs: Int?
    let framesWrittenAcrossAttempts: Int64
    let lastKnownInput: String
    let lastKnownOutput: String
    let finalRecommendedAction: String
    let routeEvents: [String]
    let recorderEvents: [String]
    let retryAccounting: [String]

    var snapshot: String {
        [
            "incidentID=\(incidentID)",
            "outcome=\(outcome)",
            "failureReason=\(failureReason.rawValue)",
            "recordingSession=\(recordingSessionID)",
            "recoveryCycle=\(recoveryCycleID)",
            "attemptCount=\(attemptCount)",
            "routeEpochStart=\(routeEpochStart)",
            "routeEpochEnd=\(routeEpochEnd)",
            "routeChangedCount=\(routeChangedCount)",
            "bluetoothModeTransitions=\(bluetoothModeTransitions.isEmpty ? "none" : bluetoothModeTransitions.joined(separator: "|"))",
            "routeStableWindowsMs=\(routeStableWindowsMs.isEmpty ? "none" : routeStableWindowsMs.map(String.init).joined(separator: "|"))",
            "firstFailureAtMs=\(firstFailureAtMs.map(String.init) ?? "nil")",
            "finalFailureAtMs=\(finalFailureAtMs.map(String.init) ?? "nil")",
            "framesWrittenAcrossAttempts=\(framesWrittenAcrossAttempts)",
            "lastKnownInput={\(lastKnownInput)}",
            "lastKnownOutput={\(lastKnownOutput)}",
            "finalRecommendedAction=\(finalRecommendedAction)",
            "routeEvents=\(routeEvents.isEmpty ? "none" : routeEvents.joined(separator: " || "))",
            "recorderEvents=\(recorderEvents.isEmpty ? "none" : recorderEvents.joined(separator: " || "))",
            "retryAccounting=\(retryAccounting.isEmpty ? "none" : retryAccounting.joined(separator: " || "))"
        ].joined(separator: " ")
    }
}

private struct ActiveFailureIncident {
    let incidentID: String
    let recoveryCycleID: String
    let recordingSessionID: String
    let routeEpochStart: Int
    let startedAtUptime: TimeInterval
    var attemptCount: Int
    var routeChangedCount: Int
    var bluetoothModeTransitions: [String]
    var routeStableWindowsMs: [Int]
    var firstFailureAtMs: Int?
    var finalFailureAtMs: Int?
    var framesWrittenAcrossAttempts: Int64
    var lastKnownInput: String
    var lastKnownOutput: String
    var routeEvents: [String]
    var recorderEvents: [String]
    var retryAccounting: [String]
    var lastFailureReason: RecordingFailureReason
}

@MainActor
final class RouteStabilityTracker {
    private(set) var routeEpoch = 0
    private(set) var lastRouteChangeUptime = ProcessInfo.processInfo.systemUptime
    private(set) var lastState = AudioDeviceDiagnostics.currentRouteState()
    private(set) var lastBluetoothMode = AudioDeviceDiagnostics.currentRouteState().bluetoothModeAssessment.mode

    func observeRouteChange(
        _ newState: AudioDeviceDiagnostics.RouteState,
        inventoryChanged: Bool
    ) -> RouteObservation {
        let now = ProcessInfo.processInfo.systemUptime
        let previousState = lastState
        let changedFields = AudioDeviceDiagnostics.routeChangedFields(from: previousState, to: newState, inventoryChanged: inventoryChanged)
        let effectiveChange = !changedFields.isEmpty && !(changedFields.count == 1 && changedFields[0] == "noEffectiveRouteChange")
        let stableForMsBeforeChange = Int((now - lastRouteChangeUptime) * 1000)
        let previousMode = lastBluetoothMode
        let assessment = newState.bluetoothModeAssessment
        if effectiveChange {
            routeEpoch += 1
            lastRouteChangeUptime = now
            lastState = newState
            lastBluetoothMode = assessment.mode
        }
        return RouteObservation(
            routeEpoch: routeEpoch,
            previousFingerprint: previousState.fingerprint,
            currentFingerprint: newState.fingerprint,
            changedFields: effectiveChange ? changedFields : ["noEffectiveRouteChange"],
            stableForMsBeforeChange: stableForMsBeforeChange,
            timeSinceAttemptStartMs: nil,
            timeSinceEngineStartMs: nil,
            bluetoothModeAssessment: assessment,
            previousBluetoothMode: previousMode,
            currentBluetoothMode: assessment.mode,
            aggregateDeviceID: AudioDeviceDiagnostics.aggregateDeviceIDsSnapshot(),
            lastObservedRouteChangeMsAgo: effectiveChange ? 0 : Int((now - lastRouteChangeUptime) * 1000),
            effectiveChange: effectiveChange
        )
    }

    func millisecondsSinceLastRouteChange() -> Int {
        Int((ProcessInfo.processInfo.systemUptime - lastRouteChangeUptime) * 1000)
    }
}

@MainActor
final class RecordingDiagnostics {
    static let shared = RecordingDiagnostics()

    private let breadcrumbLimit = 100
    private let summaryListLimit = 10
    private let routeTracker = RouteStabilityTracker()

    private var breadcrumbs: [DiagnosticsBreadcrumb] = []
    private var currentRecorderState = "idle"
    private var currentRecordingSessionID = "none"
    private var currentAttemptID = "none"
    private var currentRecoveryCycleID = "none"
    private var currentEngineInstanceID = "none"
    private var currentFailureIncidentID = "none"
    private var attemptStartUptime: TimeInterval?
    private var engineStartUptime: TimeInterval?
    private var activeIncident: ActiveFailureIncident?

    private init() {}

    func contextSnapshot(extra: [String: String] = [:]) -> String {
        var fields: [String] = [
            "recordingSession=\(currentRecordingSessionID)",
            "attempt=\(currentAttemptID)",
            "recoveryCycle=\(currentRecoveryCycleID)",
            "engineID=\(currentEngineInstanceID)",
            "failureIncidentID=\(currentFailureIncidentID)",
            "routeEpoch=\(routeTracker.routeEpoch)",
            "elapsedMsSinceAttemptStart=\(attemptStartUptime.map { String(Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)) } ?? "nil")",
            "elapsedMsSinceEngineStart=\(engineStartUptime.map { String(Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)) } ?? "nil")",
            "elapsedMsSinceLastRouteChange=\(routeTracker.millisecondsSinceLastRouteChange())",
            "currentRecorderState=\(currentRecorderState)"
        ]
        for key in extra.keys.sorted() {
            fields.append("\(key)=\(extra[key] ?? "nil")")
        }
        return fields.joined(separator: " ")
    }

    func setRecorderState(_ state: DictationState) {
        currentRecorderState = Self.string(for: state)
    }

    func setRecoveringState() {
        currentRecorderState = "recovering"
    }

    func clearRecoveryState() {
        if currentRecorderState == "recovering" {
            currentRecorderState = "idle"
        }
    }

    func isActivelyRecordingOrRecovering() -> Bool {
        currentRecorderState == "recording" || currentRecorderState == "recovering"
    }

    func beginAttempt(recordingSessionID: String, metadata: RecordingAttemptMetadata) -> RecordingAttemptContext {
        currentRecordingSessionID = recordingSessionID
        currentAttemptID = Self.shortID()
        currentEngineInstanceID = Self.shortID()
        currentRecoveryCycleID = metadata.recoveryCycleID ?? "none"
        attemptStartUptime = ProcessInfo.processInfo.systemUptime
        engineStartUptime = nil
        if var activeIncident, metadata.recoveryCycleID == activeIncident.recoveryCycleID {
            activeIncident.attemptCount += 1
            self.activeIncident = activeIncident
        }
        recordRecorderEvent(
            "attempt_started",
            detail: [
                "trigger=\(metadata.trigger)",
                "retryAttempt=\(metadata.retryAttempt)",
                "context={\(contextSnapshot())}"
            ].joined(separator: " ")
        )
        return RecordingAttemptContext(
            recordingSessionID: recordingSessionID,
            attemptID: currentAttemptID,
            engineInstanceID: currentEngineInstanceID
        )
    }

    func noteEngineStartRequested() {
        recordRecorderEvent("engine_start_requested", detail: "context={\(contextSnapshot())}")
    }

    func noteEngineStarted() {
        engineStartUptime = ProcessInfo.processInfo.systemUptime
        recordRecorderEvent("engine_start_succeeded", detail: "context={\(contextSnapshot())}")
    }

    func noteAttemptEnded(framesWritten: Int64, captureSnapshot: CaptureCadenceSnapshot, detail: String) {
        if var activeIncident {
            activeIncident.framesWrittenAcrossAttempts += framesWritten
            activeIncident.recorderEvents.appendLimited("attempt_end \(detail)")
            self.activeIncident = activeIncident
        }
        recordRecorderEvent(
            "attempt_ended",
            detail: "framesWritten=\(framesWritten) capture={\(captureSnapshot.snapshot)} \(detail)"
        )
        currentEngineInstanceID = "none"
    }

    func beginRecoveryCycleIfNeeded(recordingSessionID: String) -> String {
        if let activeIncident {
            currentFailureIncidentID = activeIncident.incidentID
            currentRecoveryCycleID = activeIncident.recoveryCycleID
            return activeIncident.recoveryCycleID
        }

        let recoveryCycleID = Self.shortID()
        let incidentID = Self.shortID()
        let now = ProcessInfo.processInfo.systemUptime
        let state = AudioDeviceDiagnostics.currentRouteState()
        let incident = ActiveFailureIncident(
            incidentID: incidentID,
            recoveryCycleID: recoveryCycleID,
            recordingSessionID: recordingSessionID,
            routeEpochStart: routeTracker.routeEpoch,
            startedAtUptime: now,
            attemptCount: 1,
            routeChangedCount: 0,
            bluetoothModeTransitions: [],
            routeStableWindowsMs: [],
            firstFailureAtMs: nil,
            finalFailureAtMs: nil,
            framesWrittenAcrossAttempts: 0,
            lastKnownInput: state.defaultInput.snapshot,
            lastKnownOutput: state.defaultOutput.snapshot,
            routeEvents: [],
            recorderEvents: [],
            retryAccounting: [],
            lastFailureReason: .unknown
        )
        activeIncident = incident
        currentFailureIncidentID = incidentID
        currentRecoveryCycleID = recoveryCycleID
        addBreadcrumb(category: "forensics", event: "recovery_cycle_started", detail: "context={\(contextSnapshot())}")
        return recoveryCycleID
    }

    func recordFailureEvent(
        _ event: RecordingFailureEvent,
        retryBudgetBefore: Int,
        retryBudgetAfter: Int,
        budgetConsumed: Bool,
        coalescedIntoExistingRecovery: Bool
    ) {
        if activeIncident == nil {
            _ = beginRecoveryCycleIfNeeded(recordingSessionID: currentRecordingSessionID)
        }
        guard var activeIncident else { return }
        let elapsedMs = attemptStartUptime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) }
        if activeIncident.firstFailureAtMs == nil {
            activeIncident.firstFailureAtMs = elapsedMs
        }
        activeIncident.finalFailureAtMs = elapsedMs
        activeIncident.framesWrittenAcrossAttempts += event.framesWritten
        activeIncident.lastKnownInput = event.routeState.defaultInput.snapshot
        activeIncident.lastKnownOutput = event.routeState.defaultOutput.snapshot
        activeIncident.lastFailureReason = event.reason
        activeIncident.recorderEvents.appendLimited("failure reason=\(event.reason.rawValue) capture={\(event.captureSnapshot.snapshot)}")
        activeIncident.retryAccounting.appendLimited(
            [
                "reason=\(event.reason.rawValue)",
                "retryBudgetBefore=\(retryBudgetBefore)",
                "retryBudgetAfter=\(retryBudgetAfter)",
                "budgetConsumed=\(AppDiagnostics.boolLabel(budgetConsumed))",
                "coalescedIntoExistingRecovery=\(AppDiagnostics.boolLabel(coalescedIntoExistingRecovery))"
            ].joined(separator: " ")
        )
        self.activeIncident = activeIncident

        addBreadcrumb(
            category: "forensics",
            event: "failure_event",
            detail: [
                "reason=\(event.reason.rawValue)",
                "reasonCategory=\(event.reason.reasonCategory)",
                "isBluetoothRelated=\(AppDiagnostics.boolLabel(event.reason.isBluetoothRelated))",
                "isRecoverable=\(AppDiagnostics.boolLabel(event.reason.isRecoverable))",
                "retryBudgetConsumes=\(AppDiagnostics.boolLabel(event.reason.retryBudgetConsumes))",
                "retryBudgetBefore=\(retryBudgetBefore)",
                "retryBudgetAfter=\(retryBudgetAfter)",
                "coalescedIntoExistingRecovery=\(AppDiagnostics.boolLabel(coalescedIntoExistingRecovery))",
                "userMessage=\(AppDiagnostics.quoted(event.userMessage, limit: 300))",
                "capture={\(event.captureSnapshot.snapshot)}",
                event.detail
            ].joined(separator: " ")
        )
    }

    func observeRouteChange(
        _ newState: AudioDeviceDiagnostics.RouteState,
        trigger: String,
        inventoryChanged: Bool,
        affectsActiveRecording: Bool,
        affectsInputPath: Bool,
        affectsOutputPath: Bool,
        likelyRecoverableWithoutRestart: Bool
    ) -> RouteObservation {
        var observation = routeTracker.observeRouteChange(newState, inventoryChanged: inventoryChanged)
        observation = RouteObservation(
            routeEpoch: observation.routeEpoch,
            previousFingerprint: observation.previousFingerprint,
            currentFingerprint: observation.currentFingerprint,
            changedFields: observation.changedFields,
            stableForMsBeforeChange: observation.stableForMsBeforeChange,
            timeSinceAttemptStartMs: attemptStartUptime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) },
            timeSinceEngineStartMs: engineStartUptime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) },
            bluetoothModeAssessment: observation.bluetoothModeAssessment,
            previousBluetoothMode: observation.previousBluetoothMode,
            currentBluetoothMode: observation.currentBluetoothMode,
            aggregateDeviceID: observation.aggregateDeviceID,
            lastObservedRouteChangeMsAgo: routeTracker.millisecondsSinceLastRouteChange(),
            effectiveChange: observation.effectiveChange
        )
        if var activeIncident {
            activeIncident.lastKnownInput = newState.defaultInput.snapshot
            activeIncident.lastKnownOutput = newState.defaultOutput.snapshot
            if observation.effectiveChange {
                activeIncident.routeChangedCount += 1
                activeIncident.routeStableWindowsMs.appendLimited(observation.stableForMsBeforeChange, limit: summaryListLimit)
                activeIncident.routeEvents.appendLimited(
                    [
                        "trigger=\(trigger)",
                        "routeEpoch=\(observation.routeEpoch)",
                        "changedFields=\(observation.changedFields.joined(separator: ","))",
                        "stableForMsBeforeChange=\(observation.stableForMsBeforeChange)",
                        "mode=\(observation.bluetoothModeAssessment.mode.rawValue)"
                    ].joined(separator: " ")
                )
                if observation.previousBluetoothMode != observation.currentBluetoothMode {
                    activeIncident.bluetoothModeTransitions.appendLimited(
                        "\(observation.previousBluetoothMode.rawValue)->\(observation.currentBluetoothMode.rawValue)@epoch\(observation.routeEpoch)"
                    )
                }
            }
            self.activeIncident = activeIncident
        }

        addBreadcrumb(
            category: "route",
            event: "route_observed",
            detail: [
                "trigger=\(trigger)",
                "changedFields=\(observation.changedFields.joined(separator: ","))",
                "affectsActiveRecording=\(AppDiagnostics.boolLabel(affectsActiveRecording))",
                "affectsInputPath=\(AppDiagnostics.boolLabel(affectsInputPath))",
                "affectsOutputPath=\(AppDiagnostics.boolLabel(affectsOutputPath))",
                "likelyRecoverableWithoutRestart=\(AppDiagnostics.boolLabel(likelyRecoverableWithoutRestart))",
                "stableForMsBeforeChange=\(observation.stableForMsBeforeChange)",
                "timeSinceAttemptStartMs=\(observation.timeSinceAttemptStartMs.map(String.init) ?? "nil")",
                "timeSinceEngineStartMs=\(observation.timeSinceEngineStartMs.map(String.init) ?? "nil")",
                "bluetoothModeGuess=\(observation.bluetoothModeAssessment.mode.rawValue)",
                "outputNominalHz=\(observation.bluetoothModeAssessment.outputNominalHz)",
                "inputNominalHz=\(observation.bluetoothModeAssessment.inputNominalHz)",
                "modeGuessConfidence=\(observation.bluetoothModeAssessment.confidence)",
                "modeGuessReason=\(observation.bluetoothModeAssessment.reason)",
                "aggregateDeviceID=\(observation.aggregateDeviceID)",
                "currentRecorderState=\(currentRecorderState)"
            ].joined(separator: " ")
        )

        if observation.previousBluetoothMode != observation.currentBluetoothMode {
            addBreadcrumb(
                category: "route",
                event: "bluetooth_mode_flip_during_attempt",
                detail: "previous=\(observation.previousBluetoothMode.rawValue) current=\(observation.currentBluetoothMode.rawValue) context={\(contextSnapshot())}"
            )
        }

        return observation
    }

    func recordRetryDecision(_ decision: RecoveryDecision, detail: String) {
        if var activeIncident {
            activeIncident.retryAccounting.appendLimited("\(decision.rawValue) \(detail)")
            self.activeIncident = activeIncident
        }
        addBreadcrumb(category: "recovery", event: decision.rawValue, detail: detail)
    }

    func recordRecorderEvent(_ event: String, detail: String) {
        if var activeIncident {
            activeIncident.recorderEvents.appendLimited("\(event) \(detail)")
            self.activeIncident = activeIncident
        }
        addBreadcrumb(category: "recorder", event: event, detail: detail)
    }

    func dumpBreadcrumbs(reason: String) {
        AppDiagnostics.warning(
            .forensics,
            "forensics breadcrumb dump reason=\(reason) count=\(breadcrumbs.count) context={\(contextSnapshot())}"
        )
        for breadcrumb in breadcrumbs {
            AppDiagnostics.warning(.forensics, "forensics breadcrumb \(breadcrumb.snapshot)")
        }
    }

    func emitIncidentSummary(outcome: String, failureReason: RecordingFailureReason) {
        guard let activeIncident else { return }
        let summary = FailureIncidentSummary(
            incidentID: activeIncident.incidentID,
            outcome: outcome,
            failureReason: failureReason,
            recordingSessionID: activeIncident.recordingSessionID,
            recoveryCycleID: activeIncident.recoveryCycleID,
            attemptCount: activeIncident.attemptCount,
            routeEpochStart: activeIncident.routeEpochStart,
            routeEpochEnd: routeTracker.routeEpoch,
            routeChangedCount: activeIncident.routeChangedCount,
            bluetoothModeTransitions: activeIncident.bluetoothModeTransitions,
            routeStableWindowsMs: activeIncident.routeStableWindowsMs,
            firstFailureAtMs: activeIncident.firstFailureAtMs,
            finalFailureAtMs: activeIncident.finalFailureAtMs,
            framesWrittenAcrossAttempts: activeIncident.framesWrittenAcrossAttempts,
            lastKnownInput: activeIncident.lastKnownInput,
            lastKnownOutput: activeIncident.lastKnownOutput,
            finalRecommendedAction: failureReason.recommendedAction,
            routeEvents: activeIncident.routeEvents,
            recorderEvents: activeIncident.recorderEvents,
            retryAccounting: activeIncident.retryAccounting
        )
        AppDiagnostics.info(.forensics, "forensics incident summary \(summary.snapshot)")
        AppDiagnostics.error(
            .forensics,
            "forensics support snapshot incidentID=\(summary.incidentID) runtime={\(AppDiagnostics.runtimeSummary)} route={\(AudioDeviceDiagnostics.currentRouteSnapshot())} devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot()) aggregateDevices=\(AudioDeviceDiagnostics.aggregateDeviceIDsSnapshot()) supportCommand=\"system_profiler SPAudioDataType SPBluetoothDataType\""
        )
        self.activeIncident = nil
        self.currentRecoveryCycleID = "none"
        self.currentFailureIncidentID = "none"
    }

    func completeRecoveryCycleIfNeeded() {
        if let activeIncident {
            emitIncidentSummary(outcome: "recovered", failureReason: activeIncident.lastFailureReason)
        }
        currentRecoveryCycleID = "none"
    }

    func clearAttemptContext() {
        currentRecordingSessionID = "none"
        currentAttemptID = "none"
        currentEngineInstanceID = "none"
        attemptStartUptime = nil
        engineStartUptime = nil
    }

    func routeEpoch() -> Int {
        routeTracker.routeEpoch
    }

    func millisecondsSinceLastRouteChange() -> Int {
        routeTracker.millisecondsSinceLastRouteChange()
    }

    private func addBreadcrumb(category: String, event: String, detail: String) {
        let breadcrumb = DiagnosticsBreadcrumb(
            timestamp: Date(),
            category: category,
            event: event,
            context: contextSnapshot(),
            detail: AppDiagnostics.compactText(detail, limit: 1200)
        )
        breadcrumbs.appendLimited(breadcrumb, limit: breadcrumbLimit)
    }

    private static func shortID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private static func string(for state: DictationState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .recording:
            return "recording"
        case .transcribing:
            return "transcribing"
        }
    }
}

private extension Array {
    mutating func appendLimited(_ element: Element, limit: Int) {
        append(element)
        if count > limit {
            removeFirst(count - limit)
        }
    }
}

private extension Array where Element == String {
    mutating func appendLimited(_ element: String) {
        append(element)
        if count > 10 {
            removeFirst(count - 10)
        }
    }
}
