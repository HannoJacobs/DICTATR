// AudioRecorder.swift
//
// Records microphone input to a 16 kHz mono WAV file using AVCaptureSession.
//
// THREADING MODEL:
//   AVCaptureAudioDataOutput delegate callbacks fire on a dedicated sample queue.
//   The real-time-ish callback never touches @Observable state directly; shared
//   counters are protected by OSAllocatedUnfairLock and surfaced back to the main
//   actor through snapshots and explicit callbacks.
//
// FORMAT PIPELINE:
//   device native audio format from AVCaptureAudioDataOutput
//     → AVAudioConverter
//     → 16kHz mono Float32 PCM  ← written to disk as WAV
//
// WHY AVCAPTURE:
//   DICTATR is a dictation app, not a live audio graph app. The previous
//   AVAudioEngine recorder path was coupled to Bluetooth HFP output-profile
//   reconfiguration and repeatedly failed before first callback on Bose/AirPods.
//   AVCaptureSession gives the app native microphone samples without making
//   dictation capture depend on AVAudioEngine’s live output graph convergence.

import AVFoundation
import Foundation
import os

struct RecordingSessionForensics {
    let routeAtStartFingerprint: String
    let routeAtStopFingerprint: String
    let routeAtStopSnapshot: String
    let lastKnownInputSnapshot: String
    let lastKnownOutputSnapshot: String
    let routeChangedDuringSession: Bool
    let captureStalledDuringSession: Bool
    let captureSnapshot: CaptureCadenceSnapshot
}

struct RealtimeCaptureStats {
    var tapCallbackCount: Int64 = 0
    var buffersReceived: Int64 = 0
    var buffersConverted: Int64 = 0
    var buffersDropped: Int64 = 0
    var framesReceivedRaw: Int64 = 0
    var framesConverted: Int64 = 0
    var largestInputBufferFrames = 0
    var smallestInputBufferFrames = Int.max
    var firstTapUptime: TimeInterval?
    var lastTapUptime: TimeInterval?
    var lastFrameWriteUptime: TimeInterval?
    var firstNonZeroWriteUptime: TimeInterval?
    var callbackIntervalTotalMs: Double = 0
    var callbackIntervalCount: Int64 = 0
}

@Observable
@MainActor
final class AudioRecorder {
    private enum StartupTimeout {
        static let firstCaptureCallbackDeadlineMs = 1500
    }

    private(set) var isRecording = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var recordingSessionID: String?

    private static let logger = Logger(subsystem: "com.dictatr", category: "AudioRecorder")
    private static let backendLabel = "captureSession"

    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingStartTime: TimeInterval?
    private var captureStartUptime: TimeInterval?
    private var durationTimer: Timer?
    private var heartbeatTimer: Timer?
    private var noAudioWatchdog: Timer?
    private var captureSessionRecorder: CaptureSessionRecorder?

    private var routeFingerprintAtStart = "unknown"
    private var lastLoggedRouteFingerprint = "unknown"
    private var lastKnownInputSnapshot = "unknown"
    private var lastKnownOutputSnapshot = "unknown"
    private var lastKnownRouteSnapshot = "unknown"
    private var lastKnownRouteState: AudioDeviceDiagnostics.RouteState?
    private var sessionObservedRouteChange = false
    private var sessionObservedCaptureStall = false
    private var lastHeartbeatFramesWritten: Int64 = 0
    private var selectedCaptureDeviceUID = "unknown"
    private var selectedCaptureDeviceName = "unknown"
    private var activeAttemptMetadata: RecordingAttemptMetadata = .userHotkey
    private var routingArbitrationActive = false

    var onRecordingFailed: ((RecordingFailureEvent) -> Void)?
    var onRecordingStable: (() -> Void)?

    private let _isCapturing = OSAllocatedUnfairLock(initialState: false)
    private let _framesWritten = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _droppedFrames = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _captureStats = OSAllocatedUnfairLock(initialState: RealtimeCaptureStats())

    func startRecording(metadata: RecordingAttemptMetadata = .userHotkey) async throws -> URL {
        if isRecording {
            AppDiagnostics.warning(
                .audioRecorder,
                "startRecording while already recording session=\(recordingSessionID ?? "none") — cleaning up previous session"
            )
            if let result = stopRecording() {
                try? FileManager.default.removeItem(at: result.url)
            }
        }

        let sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        recordingSessionID = sessionID
        activeAttemptMetadata = metadata
        let attemptContext = RecordingDiagnostics.shared.beginAttempt(recordingSessionID: sessionID, metadata: metadata)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictatr_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        let startRouteState = AudioDeviceDiagnostics.currentRouteState()
        _captureStats.withLock { $0 = RealtimeCaptureStats() }

        AppDiagnostics.info(
            .audioRecorder,
            "recording start requested \(AppDiagnostics.recordingVersionSummary) context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["trigger": metadata.trigger, "retryAttempt": String(metadata.retryAttempt), "attempt": attemptContext.attemptID, "engineID": attemptContext.engineInstanceID, "backend": Self.backendLabel]))} outputFile=\(fileURL.lastPathComponent) routeFingerprint=\(startRouteState.fingerprint) activeInput={\(startRouteState.defaultInput.snapshot)} activeOutput={\(startRouteState.defaultOutput.snapshot)} route=\(startRouteState.routeSnapshot) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        RecordingDiagnostics.shared.recordRecorderEvent(
            "recording_backend_selected",
            detail: "trigger=\(metadata.trigger) retryAttempt=\(metadata.retryAttempt) backend=\(Self.backendLabel) file=\(fileURL.lastPathComponent)"
        )
        RecordingDiagnostics.shared.recordRecorderEvent(
            "capture_session_expected_input",
            detail: "expectedInputUID=\(startRouteState.defaultInput.uid) expectedInputName=\(startRouteState.defaultInput.name) availableCaptureDevices=\(CaptureDeviceSelection.availableSnapshot())"
        )

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatCreationFailed
        }

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        outputFile = file
        outputURL = fileURL
        routeFingerprintAtStart = startRouteState.fingerprint
        lastLoggedRouteFingerprint = startRouteState.fingerprint
        lastKnownInputSnapshot = startRouteState.defaultInput.snapshot
        lastKnownOutputSnapshot = startRouteState.defaultOutput.snapshot
        lastKnownRouteSnapshot = startRouteState.routeSnapshot
        lastKnownRouteState = startRouteState
        sessionObservedRouteChange = false
        sessionObservedCaptureStall = false
        lastHeartbeatFramesWritten = 0
        selectedCaptureDeviceUID = "unknown"
        selectedCaptureDeviceName = "unknown"
        _isCapturing.withLock { $0 = true }
        _framesWritten.withLock { $0 = 0 }
        _droppedFrames.withLock { $0 = 0 }
        isRecording = true
        recordingDuration = 0
        recordingStartTime = ProcessInfo.processInfo.systemUptime
        captureStartUptime = ProcessInfo.processInfo.systemUptime

        beginRoutingArbitrationIfNeeded(category: .playAndRecord)

        let recorder = CaptureSessionRecorder(
            targetFormat: targetFormat,
            outputFile: file,
            isCapturing: _isCapturing,
            framesWritten: _framesWritten,
            droppedFrames: _droppedFrames,
            captureStats: _captureStats,
            onFirstSample: { [weak self] sourceFormat in
                self?.handleFirstCaptureSample(sourceFormat)
            },
            onEvent: { event, detail in
                RecordingDiagnostics.shared.recordRecorderEvent(event, detail: detail)
            },
            onFailure: { [weak self] event in
                self?.handleCaptureSessionFailure(event: event)
            }
        )
        captureSessionRecorder = recorder

        RecordingDiagnostics.shared.noteCaptureStartRequested()

        let startResult: CaptureSessionStartResult
        do {
            startResult = try await recorder.start(
                expectedInputDeviceUID: startRouteState.defaultInput.uid,
                startupTimeoutMs: StartupTimeout.firstCaptureCallbackDeadlineMs
            )
            RecordingDiagnostics.shared.noteCaptureStarted()
        } catch {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "capture_session_start_failed",
                detail: "error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))} routeFingerprint=\(startRouteState.fingerprint)"
            )
            AppDiagnostics.error(
                .audioRecorder,
                "capture session failed to start context={\(RecordingDiagnostics.shared.contextSnapshot())} backend=\(Self.backendLabel) error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))} route=\(startRouteState.routeSnapshot) availableCaptureDevices=\(CaptureDeviceSelection.availableSnapshot())"
            )
            cleanupAfterFailedStart(fileURL: fileURL)
            throw error
        }

        selectedCaptureDeviceUID = startResult.selectedDeviceUID
        selectedCaptureDeviceName = startResult.selectedDeviceName
        let startedRouteState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: startedRouteState)

        RecordingDiagnostics.shared.recordRecorderEvent(
            "capture_session_started",
            detail: "selectedDeviceUID=\(selectedCaptureDeviceUID) selectedDeviceName=\(selectedCaptureDeviceName) firstSampleFormat={\(startResult.firstSampleFormat.description)} routeFingerprint=\(startedRouteState.fingerprint)"
        )
        AppDiagnostics.info(
            .audioRecorder,
            "capture session started context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": Self.backendLabel]))} file=\(fileURL.lastPathComponent) routeFingerprintAtStart=\(routeFingerprintAtStart) routeFingerprintAtCaptureStart=\(startedRouteState.fingerprint) routeChangedBeforeCaptureStart=\(AppDiagnostics.boolLabel(routeFingerprintAtStart != startedRouteState.fingerprint)) selectedDeviceUID=\(selectedCaptureDeviceUID) selectedDeviceName=\(selectedCaptureDeviceName) firstSampleFormat={\(startResult.firstSampleFormat.description)} activeInput={\(startedRouteState.defaultInput.snapshot)} activeOutput={\(startedRouteState.defaultOutput.snapshot)} route=\(startedRouteState.routeSnapshot)"
        )

        attachRecordingTimers()

        return fileURL
    }

    func stopRecording() -> (url: URL, duration: TimeInterval, framesWritten: Int64, forensics: RecordingSessionForensics)? {
        guard isRecording, let url = outputURL else { return nil }
        let captureSnapshot = captureSnapshot()

        _isCapturing.withLock { $0 = false }
        isRecording = false

        durationTimer?.invalidate()
        durationTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil
        RecordingDiagnostics.shared.recordRecorderEvent("timers_detached", detail: "heartbeatTimer=no durationTimer=no watchdog=no")

        let duration: TimeInterval
        if let start = recordingStartTime {
            duration = ProcessInfo.processInfo.systemUptime - start
        } else {
            duration = recordingDuration
        }

        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }
        let stopRouteState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: stopRouteState)

        captureSessionRecorder?.stop()
        captureSessionRecorder = nil
        outputFile = nil
        recordingStartTime = nil
        captureStartUptime = nil
        leaveRoutingArbitrationIfNeeded()

        AppDiagnostics.info(
            .audioRecorder,
            "recording stopped context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": Self.backendLabel, "selectedDeviceUID": selectedCaptureDeviceUID, "selectedDeviceName": selectedCaptureDeviceName]))} duration=\(String(format: "%.3f", duration))s frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} file=\(url.lastPathComponent) routeAtStartFingerprint=\(routeFingerprintAtStart) routeAtStopFingerprint=\(stopRouteState.fingerprint) routeChangedDuringSession=\(AppDiagnostics.boolLabel(sessionObservedRouteChange)) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(sessionObservedCaptureStall)) lastKnownInput={\(lastKnownInputSnapshot)} lastKnownOutput={\(lastKnownOutputSnapshot)} route=\(stopRouteState.routeSnapshot) fileExists=\(AppDiagnostics.boolLabel(FileManager.default.fileExists(atPath: url.path)))"
        )
        RecordingDiagnostics.shared.noteAttemptEnded(
            framesWritten: frames,
            captureSnapshot: captureSnapshot,
            detail: "durationMs=\(Int(duration * 1000)) routeChangedDuringSession=\(AppDiagnostics.boolLabel(sessionObservedRouteChange))"
        )

        let forensics = RecordingSessionForensics(
            routeAtStartFingerprint: routeFingerprintAtStart,
            routeAtStopFingerprint: stopRouteState.fingerprint,
            routeAtStopSnapshot: stopRouteState.routeSnapshot,
            lastKnownInputSnapshot: lastKnownInputSnapshot,
            lastKnownOutputSnapshot: lastKnownOutputSnapshot,
            routeChangedDuringSession: sessionObservedRouteChange,
            captureStalledDuringSession: sessionObservedCaptureStall,
            captureSnapshot: captureSnapshot
        )

        resetSessionForensics()
        recordingSessionID = nil
        activeAttemptMetadata = .userHotkey
        RecordingDiagnostics.shared.clearAttemptContext()

        return (url, duration, frames, forensics)
    }

    func forceReset(reason: String = "unspecified") {
        let sessionID = recordingSessionID ?? "none"
        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }
        let captureSnapshot = captureSnapshot()

        RecordingDiagnostics.shared.recordRecorderEvent(
            "force_reset_started",
            detail: "reason=\(reason) capture={\(captureSnapshot.snapshot)}"
        )
        AppDiagnostics.warning(
            .audioRecorder,
            "force reset context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": Self.backendLabel, "selectedDeviceUID": selectedCaptureDeviceUID, "selectedDeviceName": selectedCaptureDeviceName]))} session=\(sessionID) reason=\(reason) elapsed=\(elapsedRecordingTime()) frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} route=\(AudioDeviceDiagnostics.currentRouteSnapshot()) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )

        _isCapturing.withLock { $0 = false }
        durationTimer?.invalidate()
        durationTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil
        RecordingDiagnostics.shared.recordRecorderEvent("timers_detached", detail: "heartbeatTimer=no durationTimer=no watchdog=no")

        captureSessionRecorder?.forceReset()
        captureSessionRecorder = nil
        outputFile = nil
        recordingStartTime = nil
        captureStartUptime = nil
        leaveRoutingArbitrationIfNeeded()
        isRecording = false
        recordingDuration = 0
        recordingSessionID = nil
        activeAttemptMetadata = .userHotkey
        resetSessionForensics()
        RecordingDiagnostics.shared.recordRecorderEvent("force_reset_completed", detail: "reason=\(reason)")
        RecordingDiagnostics.shared.clearAttemptContext()

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
        }
    }

    private func cleanupAfterFailedStart(fileURL: URL) {
        AppDiagnostics.warning(
            .audioRecorder,
            "cleanup after failed start context={\(RecordingDiagnostics.shared.contextSnapshot())} session=\(recordingSessionID ?? "none") file=\(fileURL.lastPathComponent)"
        )
        RecordingDiagnostics.shared.recordRecorderEvent("cleanup_after_failed_start", detail: "file=\(fileURL.lastPathComponent)")
        _isCapturing.withLock { $0 = false }
        captureSessionRecorder?.forceReset()
        captureSessionRecorder = nil
        outputFile = nil
        outputURL = nil
        isRecording = false
        recordingDuration = 0
        recordingStartTime = nil
        captureStartUptime = nil
        leaveRoutingArbitrationIfNeeded()
        recordingSessionID = nil
        activeAttemptMetadata = .userHotkey
        resetSessionForensics()
        RecordingDiagnostics.shared.clearAttemptContext()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func beginRoutingArbitrationIfNeeded(category: AVAudioRoutingArbiter.Category) {
        guard !routingArbitrationActive else { return }
        guard #available(macOS 11.0, *) else { return }

        AVAudioRoutingArbiter.shared.begin(category: category) { defaultDeviceChanged, error in
            Task { @MainActor in
                if let error {
                    RecordingDiagnostics.shared.recordRecorderEvent(
                        "routing_arbiter_begin_failed",
                        detail: "defaultDeviceChanged=\(AppDiagnostics.boolLabel(defaultDeviceChanged)) error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
                    )
                    AppDiagnostics.warning(
                        .audioRecorder,
                        "routing arbitration begin failed context={\(RecordingDiagnostics.shared.contextSnapshot())} defaultDeviceChanged=\(AppDiagnostics.boolLabel(defaultDeviceChanged)) error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
                    )
                    return
                }

                self.routingArbitrationActive = true
                RecordingDiagnostics.shared.recordRecorderEvent(
                    "routing_arbiter_begin_succeeded",
                    detail: "defaultDeviceChanged=\(AppDiagnostics.boolLabel(defaultDeviceChanged))"
                )
                AppDiagnostics.info(
                    .audioRecorder,
                    "routing arbitration begun context={\(RecordingDiagnostics.shared.contextSnapshot())} defaultDeviceChanged=\(AppDiagnostics.boolLabel(defaultDeviceChanged))"
                )
            }
        }
    }

    private func leaveRoutingArbitrationIfNeeded() {
        guard routingArbitrationActive else { return }
        guard #available(macOS 11.0, *) else { return }

        AVAudioRoutingArbiter.shared.leave()
        routingArbitrationActive = false
        RecordingDiagnostics.shared.recordRecorderEvent("routing_arbiter_left", detail: "backend=\(Self.backendLabel)")
    }

    private func attachRecordingTimers() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = ProcessInfo.processInfo.systemUptime - start
            }
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.emitRecordingHeartbeat()
            }
        }

        noAudioWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkNoAudioWatchdog()
            }
        }
    }

    private func handleFirstCaptureSample(_ sourceFormat: AudioGraphFormatSnapshot) {
        let routeState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: routeState)
        RecordingDiagnostics.shared.recordRecorderEvent(
            "first_capture_sample_seen",
            detail: "backend=\(Self.backendLabel) selectedDeviceUID=\(selectedCaptureDeviceUID) selectedDeviceName=\(selectedCaptureDeviceName) sourceFormat={\(sourceFormat.description)} routeFingerprint=\(routeState.fingerprint)"
        )
    }

    private func handleCaptureSessionFailure(event: CaptureSessionFailureEvent) {
        guard isRecording else { return }

        let routeState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: routeState)
        let captureSnapshot = captureSnapshot()
        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }

        AppDiagnostics.error(
            .audioRecorder,
            "capture session failure context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": Self.backendLabel, "selectedDeviceUID": selectedCaptureDeviceUID, "selectedDeviceName": selectedCaptureDeviceName]))} reason=\(event.reason.rawValue) frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} route=\(routeState.routeSnapshot) detail={\(event.detail)}"
        )

        forceReset(reason: event.detail)
        onRecordingFailed?(
            RecordingFailureEvent(
                reason: event.reason,
                userMessage: event.reason.defaultUserMessage,
                framesWritten: frames,
                droppedFrames: dropped,
                routeState: routeState,
                captureSnapshot: captureSnapshot,
                detail: event.detail
            )
        )
    }

    private func handleCaptureInputDeviceChanged(routeState: AudioDeviceDiagnostics.RouteState) {
        let detail = "selectedCaptureDeviceUID=\(selectedCaptureDeviceUID) currentDefaultInputUID=\(routeState.defaultInput.uid) currentDefaultInput={\(routeState.defaultInput.snapshot)}"
        handleCaptureSessionFailure(
            event: CaptureSessionFailureEvent(reason: .captureInputDeviceChanged, detail: detail)
        )
    }

    private func checkNoAudioWatchdog() {
        guard isRecording else { return }
        let frames = _framesWritten.withLock { $0 }
        let captureSnapshot = captureSnapshot()
        if frames < 800 {
            let routeState = AudioDeviceDiagnostics.currentRouteState()
            updateRouteTracking(with: routeState)
            AppDiagnostics.error(
                .audioRecorder,
                "watchdog fired context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": Self.backendLabel, "selectedDeviceUID": selectedCaptureDeviceUID]))} frames=\(frames) dropped=\(_droppedFrames.withLock { $0 }) elapsed=\(elapsedRecordingTime()) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(sessionObservedCaptureStall)) lastKnownInput={\(lastKnownInputSnapshot)} lastKnownOutput={\(lastKnownOutputSnapshot)} route=\(routeState.routeSnapshot)"
            )
            let reason: RecordingFailureReason = routeState.activeRouteInvolvesBluetooth ? .noAudioWatchdogTimeout : .captureStalled
            forceReset(reason: "watchdog no audio after 5 seconds")
            RecordingDiagnostics.shared.dumpBreadcrumbs(reason: "watchdog_fired")
            onRecordingFailed?(
                RecordingFailureEvent(
                    reason: reason,
                    userMessage: reason.defaultUserMessage,
                    framesWritten: frames,
                    droppedFrames: _droppedFrames.withLock { $0 },
                    routeState: routeState,
                    captureSnapshot: captureSnapshot,
                    detail: "watchdog fired routeFingerprint=\(routeState.fingerprint)"
                )
            )
        } else {
            AppDiagnostics.info(
                .audioRecorder,
                "watchdog healthy context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": Self.backendLabel]))} frames=\(frames) dropped=\(_droppedFrames.withLock { $0 }) elapsed=\(elapsedRecordingTime()) capture={\(captureSnapshot.snapshot)}"
            )
            onRecordingStable?()
        }
    }

    private func elapsedRecordingTime() -> String {
        guard let start = recordingStartTime else { return "unknown" }
        return String(format: "%.3fs", ProcessInfo.processInfo.systemUptime - start)
    }

    private func emitRecordingHeartbeat() {
        guard isRecording else { return }

        let routeState = AudioDeviceDiagnostics.currentRouteState()
        if selectedCaptureDeviceUID != "unknown", routeState.defaultInput.uid != selectedCaptureDeviceUID {
            handleCaptureInputDeviceChanged(routeState: routeState)
            return
        }

        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }
        let delta = frames - lastHeartbeatFramesWritten
        lastHeartbeatFramesWritten = frames
        let captureStalled = delta <= 0
        if captureStalled {
            sessionObservedCaptureStall = true
        }

        let previousFingerprint = lastLoggedRouteFingerprint
        updateRouteTracking(with: routeState)
        let captureSnapshot = captureSnapshot()
        let lastRouteChangeMs = RecordingDiagnostics.shared.millisecondsSinceLastRouteChange()

        let baseMessage =
            "recording heartbeat context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["captureState": captureSnapshot.captureState, "lastObservedRouteChangeMsAgo": String(lastRouteChangeMs), "backend": Self.backendLabel, "selectedDeviceUID": selectedCaptureDeviceUID, "selectedDeviceName": selectedCaptureDeviceName]))} elapsed=\(elapsedRecordingTime()) sessionRunning=\(AppDiagnostics.boolLabel(captureSessionRecorder?.isRunning ?? false)) frames=\(frames) dropped=\(dropped) deltaFrames=\(delta) captureStalled=\(AppDiagnostics.boolLabel(captureStalled)) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint) activeInput={\(routeState.defaultInput.snapshot)} activeOutput={\(routeState.defaultOutput.snapshot)} bluetoothInput=\(AppDiagnostics.boolLabel(routeState.defaultInputIsBluetooth)) bluetoothOutput=\(AppDiagnostics.boolLabel(routeState.defaultOutputIsBluetooth)) bluetoothRoute=\(AppDiagnostics.boolLabel(routeState.activeRouteInvolvesBluetooth))"

        if previousFingerprint != routeState.fingerprint {
            AppDiagnostics.info(
                .audioRecorder,
                "\(baseMessage) routeFingerprintChanged=yes previousRouteFingerprint=\(previousFingerprint) route=\(routeState.routeSnapshot)"
            )
        } else {
            AppDiagnostics.info(.audioRecorder, baseMessage)
        }
    }

    private func updateRouteTracking(with routeState: AudioDeviceDiagnostics.RouteState) {
        if lastLoggedRouteFingerprint != "unknown", lastLoggedRouteFingerprint != routeState.fingerprint {
            sessionObservedRouteChange = true
        }
        lastLoggedRouteFingerprint = routeState.fingerprint
        lastKnownInputSnapshot = routeState.defaultInput.snapshot
        lastKnownOutputSnapshot = routeState.defaultOutput.snapshot
        lastKnownRouteSnapshot = routeState.routeSnapshot
        lastKnownRouteState = routeState
    }

    private func resetSessionForensics() {
        routeFingerprintAtStart = "unknown"
        lastLoggedRouteFingerprint = "unknown"
        lastKnownInputSnapshot = "unknown"
        lastKnownOutputSnapshot = "unknown"
        lastKnownRouteSnapshot = "unknown"
        lastKnownRouteState = nil
        sessionObservedRouteChange = false
        sessionObservedCaptureStall = false
        lastHeartbeatFramesWritten = 0
        captureStartUptime = nil
        selectedCaptureDeviceUID = "unknown"
        selectedCaptureDeviceName = "unknown"
        _captureStats.withLock { $0 = RealtimeCaptureStats() }
    }

    private static func describe(error: Error) -> String {
        let nsError = error as NSError
        let userInfo = nsError.userInfo
            .map { "\($0.key)=\(AppDiagnostics.compactText(String(describing: $0.value), limit: 200))" }
            .sorted()
            .joined(separator: ",")
        return "domain=\(nsError.domain) code=\(nsError.code) localizedDescription=\(nsError.localizedDescription) userInfo={\(userInfo)}"
    }

    private func captureSnapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CaptureCadenceSnapshot {
        let stats = _captureStats.withLock { $0 }
        let tapCallbacks = stats.tapCallbackCount
        let avgInterval = stats.callbackIntervalCount > 0 ? Int(stats.callbackIntervalTotalMs / Double(stats.callbackIntervalCount)) : nil
        let firstTapMs = msSinceCaptureStart(stats.firstTapUptime)
        let firstWriteMs = msSinceCaptureStart(stats.firstNonZeroWriteUptime)
        let lastTapAgo = msAgo(stats.lastTapUptime, now: now)
        let firstTapAgo = msAgo(stats.firstTapUptime, now: now)
        let lastWriteAgo = msAgo(stats.lastFrameWriteUptime, now: now)
        let framesWritten = _framesWritten.withLock { $0 }

        let captureState: String
        if tapCallbacks == 0 {
            captureState = "never_started"
        } else if framesWritten == 0 {
            captureState = "warming_up"
        } else if let lastTapAgo, lastTapAgo > 1000 {
            captureState = "stalled"
        } else {
            captureState = "flowing"
        }

        return CaptureCadenceSnapshot(
            firstTapCallbackMs: firstTapMs,
            tapCallbackCount: tapCallbacks,
            lastTapCallbackMsAgo: lastTapAgo,
            buffersReceived: stats.buffersReceived,
            buffersConverted: stats.buffersConverted,
            buffersDropped: stats.buffersDropped,
            framesReceivedRaw: stats.framesReceivedRaw,
            framesConverted: stats.framesConverted,
            framesWritten: framesWritten,
            largestInputBufferFrames: stats.largestInputBufferFrames,
            smallestInputBufferFrames: stats.smallestInputBufferFrames == Int.max ? 0 : stats.smallestInputBufferFrames,
            avgCallbackIntervalMs: avgInterval,
            timeSinceFirstTapMs: firstTapAgo,
            timeSinceLastTapMs: lastTapAgo,
            timeSinceLastFrameWriteMs: lastWriteAgo,
            captureState: captureState,
            firstNonZeroWriteMs: firstWriteMs
        )
    }

    private func msSinceCaptureStart(_ uptime: TimeInterval?) -> Int? {
        guard let uptime, let captureStartUptime else { return nil }
        return Int((uptime - captureStartUptime) * 1000)
    }

    private func msAgo(_ uptime: TimeInterval?, now: TimeInterval) -> Int? {
        guard let uptime else { return nil }
        return Int((now - uptime) * 1000)
    }
}

enum AudioRecorderError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case captureDeviceUnavailable
    case captureDeviceSelectionFailed(String)
    case captureSessionConfigurationFailed(String)
    case captureSessionRuntimeError(String)
    case captureStartupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create target audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .captureDeviceUnavailable:
            return "No microphone device is available for AVCaptureSession"
        case .captureDeviceSelectionFailed(let detail),
             .captureSessionConfigurationFailed(let detail),
             .captureSessionRuntimeError(let detail),
             .captureStartupTimedOut(let detail):
            return detail
        }
    }
}
