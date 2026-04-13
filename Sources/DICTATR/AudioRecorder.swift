// AudioRecorder.swift
//
// Records microphone input to a 16 kHz mono WAV file — the format WhisperKit expects.
//
// THREADING MODEL:
//   AVAudioEngine's tap callback fires on a real-time audio thread, NOT the main actor.
//   All @Observable stored properties are main-actor-only. Accessing them from the audio
//   thread is a data race. Solution: OSAllocatedUnfairLock(_isCapturing) is the only
//   shared state read from the audio thread. Everything else is accessed via captured
//   locals (the `file` capture in the tap closure).
//
// FORMAT PIPELINE:
//   inputNode output format (device native, e.g. 48kHz stereo)
//     → AVAudioConverter
//     → 16kHz mono Float32 PCM  ← written to disk as WAV
//
// LIFECYCLE:
//   startRecording() → installs tap, starts engine, returns URL
//   stopRecording()  → signals tap to stop (atomic), removes tap, stops engine, returns (url, duration)
//   The caller (AppState) owns cleanup of the WAV file after transcription.
//
// BLUETOOTH HFP HANDLING (v1.31):
//   Bluetooth routes often look "ready" before engine.start(), then collapse from a
//   high-fidelity output rate to a telephony rate while the engine is already starting.
//   The recorder therefore:
//
//   1. Logs both inputNode.inputFormat(forBus: 0) and outputFormat(forBus: 0) before
//      and after engine.start().
//   2. Starts the engine before installing the tap, so it never commits a Bluetooth
//      tap from a stale pre-start format.
//   3. Installs the tap only when the live graph reports valid, matching input/output
//      formats.
//   4. Uses a short startup deadline keyed off the first capture callback rather than
//      route quiet, so retries succeed only when the graph is genuinely ready.

import AVFoundation
import CoreAudio
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

    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingStartTime: TimeInterval?
    private var engineStartUptime: TimeInterval?
    private var durationTimer: Timer?
    private var heartbeatTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var noAudioWatchdog: Timer?
    private var startupDeadlineTimer: Timer?
    private var captureSessionRecorder: CaptureSessionRecorder?

    /// Stored for tap reinstallation after config changes.
    private var activeTargetFormat: AVAudioFormat?
    private var activeRouteInvolvesBluetooth = false
    private var routeFingerprintAtStart = "unknown"
    private var lastLoggedRouteFingerprint = "unknown"
    private var lastKnownInputSnapshot = "unknown"
    private var lastKnownOutputSnapshot = "unknown"
    private var lastKnownRouteSnapshot = "unknown"
    private var lastKnownRouteState: AudioDeviceDiagnostics.RouteState?
    private var sessionObservedRouteChange = false
    private var sessionObservedCaptureStall = false
    private var lastHeartbeatFramesWritten: Int64 = 0
    private var activeBackendKind: RecorderBackendKind = .audioEngine
    private var activeAttemptMetadata: RecordingAttemptMetadata = .userHotkey
    private var routingArbitrationActive = false

    var onRecordingFailed: ((RecordingFailureEvent) -> Void)?
    var onRecordingStable: (() -> Void)?

    // Thread-safe flags readable from the real-time audio thread.
    private let _isCapturing = OSAllocatedUnfairLock(initialState: false)
    private let _framesWritten = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _droppedFrames = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _captureStats = OSAllocatedUnfairLock(initialState: RealtimeCaptureStats())

    func startRecording(metadata: RecordingAttemptMetadata = .userHotkey) throws -> URL {
        // Guard against double-start
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
        activeBackendKind = RecorderBackendSelection.current()
        let attemptContext = RecordingDiagnostics.shared.beginAttempt(recordingSessionID: sessionID, metadata: metadata)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictatr_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        let startRouteState = AudioDeviceDiagnostics.currentRouteState()
        _captureStats.withLock { $0 = RealtimeCaptureStats() }

        AppDiagnostics.info(
            .audioRecorder,
            "recording start requested \(AppDiagnostics.recordingVersionSummary) context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["trigger": metadata.trigger, "retryAttempt": String(metadata.retryAttempt), "attempt": attemptContext.attemptID, "engineID": attemptContext.engineInstanceID, "backend": activeBackendKind.rawValue]))} outputFile=\(fileURL.lastPathComponent) routeFingerprint=\(startRouteState.fingerprint) activeInput={\(startRouteState.defaultInput.snapshot)} activeOutput={\(startRouteState.defaultOutput.snapshot)} route=\(startRouteState.routeSnapshot) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        RecordingDiagnostics.shared.recordRecorderEvent(
            "recording_backend_selected",
            detail: "trigger=\(metadata.trigger) retryAttempt=\(metadata.retryAttempt) backend=\(activeBackendKind.rawValue) file=\(fileURL.lastPathComponent)"
        )

        // Target format: 16kHz mono Float32 (what Whisper expects)
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

        self.outputFile = file
        self.outputURL = fileURL
        self.activeTargetFormat = targetFormat
        self.activeRouteInvolvesBluetooth = startRouteState.activeRouteInvolvesBluetooth
        self.routeFingerprintAtStart = startRouteState.fingerprint
        self.lastLoggedRouteFingerprint = startRouteState.fingerprint
        self.lastKnownInputSnapshot = startRouteState.defaultInput.snapshot
        self.lastKnownOutputSnapshot = startRouteState.defaultOutput.snapshot
        self.lastKnownRouteSnapshot = startRouteState.routeSnapshot
        self.sessionObservedRouteChange = false
        self.sessionObservedCaptureStall = false
        self.lastHeartbeatFramesWritten = 0
        self._isCapturing.withLock { $0 = true }
        self._framesWritten.withLock { $0 = 0 }
        self._droppedFrames.withLock { $0 = 0 }
        self.isRecording = true
        self.recordingDuration = 0
        self.recordingStartTime = ProcessInfo.processInfo.systemUptime
        self.engineStartUptime = nil

        beginRoutingArbitrationIfNeeded(category: .playAndRecord)

        switch activeBackendKind {
        case .audioEngine:
            try startEngineRecording(fileURL: fileURL, file: file, targetFormat: targetFormat, startRouteState: startRouteState)
        case .captureSession:
            try startCaptureSessionRecording(fileURL: fileURL, file: file, targetFormat: targetFormat, startRouteState: startRouteState)
        }

        attachRecordingTimers()

        return fileURL
    }

    private func startEngineRecording(
        fileURL: URL,
        file: AVAudioFile,
        targetFormat: AVAudioFormat,
        startRouteState: AudioDeviceDiagnostics.RouteState
    ) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        audioEngine = engine

        let prestartFormats = currentGraphFormats(for: inputNode)
        recordGraphFormats(
            prestartFormats,
            event: "prestart_graph_formats_observed",
            routeState: startRouteState,
            detail: "phase=prestart backend=\(activeBackendKind.rawValue)"
        )
        let prestartDecision = RecordingStartupGate.tapInstallDecision(
            routeInvolvesBluetooth: startRouteState.activeRouteInvolvesBluetooth,
            inputFormat: prestartFormats.inputSnapshot,
            outputFormat: prestartFormats.outputSnapshot,
            expectedInputSampleRate: Double(startRouteState.defaultInput.nominalHz)
        )
        if !prestartDecision.shouldInstallTap {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "stale_prestart_format",
                detail: "backend=\(activeBackendKind.rawValue) \(prestartDecision.detail) reason=\(prestartDecision.reason.rawValue)"
            )
            AppDiagnostics.warning(
                .audioRecorder,
                "recording start stale prestart format context={\(RecordingDiagnostics.shared.contextSnapshot())} reason=\(prestartDecision.reason.rawValue) \(prestartDecision.detail) route=\(startRouteState.routeSnapshot)"
            )
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
        RecordingDiagnostics.shared.recordRecorderEvent("config_observer_attached", detail: "observerInstalled=yes backend=audioEngine")

        do {
            RecordingDiagnostics.shared.noteEngineStartRequested()
            try engine.start()
            engineStartUptime = ProcessInfo.processInfo.systemUptime
            RecordingDiagnostics.shared.noteEngineStarted()
        } catch {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "engine_start_failed",
                detail: "error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
            )
            AppDiagnostics.error(
                .audioRecorder,
                "engine failed to start context={\(RecordingDiagnostics.shared.contextSnapshot())} backend=audioEngine error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))} route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            cleanupAfterFailedStart(fileURL: fileURL)
            throw error
        }

        let engineStartedRouteState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: engineStartedRouteState)
        let postStartDecision = try tryInstallTapIfHardwareFormatReady(
            on: inputNode,
            targetFormat: targetFormat,
            file: file,
            routeState: engineStartedRouteState,
            event: "post_start_graph_formats_observed",
            readyEvent: "post_start_format_ready",
            staleEvent: "post_start_graph_stale"
        )
        AppDiagnostics.info(
            .audioRecorder,
            "engine started context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": activeBackendKind.rawValue, "tapInstalled": AppDiagnostics.boolLabel(postStartDecision.shouldInstallTap)]))} file=\(fileURL.lastPathComponent) routeFingerprintAtStart=\(routeFingerprintAtStart) routeFingerprintAtEngineStart=\(engineStartedRouteState.fingerprint) routeChangedBeforeEngineStart=\(AppDiagnostics.boolLabel(routeFingerprintAtStart != engineStartedRouteState.fingerprint)) activeInput={\(engineStartedRouteState.defaultInput.snapshot)} activeOutput={\(engineStartedRouteState.defaultOutput.snapshot)} route=\(engineStartedRouteState.routeSnapshot)"
        )

        startStartupDeadline(routeState: engineStartedRouteState, graphReady: postStartDecision.shouldInstallTap)
    }

    private func startCaptureSessionRecording(
        fileURL: URL,
        file: AVAudioFile,
        targetFormat: AVAudioFormat,
        startRouteState: AudioDeviceDiagnostics.RouteState
    ) throws {
        _ = fileURL
        _ = startRouteState
        let recorder = CaptureSessionRecorder(
            targetFormat: targetFormat,
            outputFile: file,
            isCapturing: _isCapturing,
            framesWritten: _framesWritten,
            droppedFrames: _droppedFrames,
            captureStats: _captureStats,
            onFirstSample: { [weak self] sourceFormat in
                self?.handleFirstCaptureCallback(sourceFormat: sourceFormat, event: "first_tap_seen")
            },
            onEvent: { event, detail in
                RecordingDiagnostics.shared.recordRecorderEvent(event, detail: detail)
            }
        )
        do {
            try recorder.start()
            captureSessionRecorder = recorder
            RecordingDiagnostics.shared.recordRecorderEvent(
                "capture_session_started",
                detail: "backend=captureSession targetFormat={\(AudioGraphFormatSnapshot(targetFormat).description)}"
            )
            startStartupDeadline(routeState: AudioDeviceDiagnostics.currentRouteState(), graphReady: false)
        } catch {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "capture_session_start_failed",
                detail: "error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
            )
            cleanupAfterFailedStart(fileURL: fileURL)
            throw error
        }
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
        RecordingDiagnostics.shared.recordRecorderEvent("routing_arbiter_left", detail: "backend=\(activeBackendKind.rawValue)")
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

    private func startStartupDeadline(routeState: AudioDeviceDiagnostics.RouteState, graphReady: Bool) {
        startupDeadlineTimer?.invalidate()
        RecordingDiagnostics.shared.recordRecorderEvent(
            "startup_deadline_started",
            detail: "backend=\(activeBackendKind.rawValue) deadlineMs=\(StartupTimeout.firstCaptureCallbackDeadlineMs) graphReady=\(AppDiagnostics.boolLabel(graphReady)) routeFingerprint=\(routeState.fingerprint)"
        )
        startupDeadlineTimer = Timer.scheduledTimer(
            withTimeInterval: Double(StartupTimeout.firstCaptureCallbackDeadlineMs) / 1000.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleStartupDeadline()
            }
        }
    }

    private func cancelStartupDeadline(reason: String) {
        startupDeadlineTimer?.invalidate()
        startupDeadlineTimer = nil
        RecordingDiagnostics.shared.recordRecorderEvent("startup_deadline_cancelled", detail: "reason=\(reason) backend=\(activeBackendKind.rawValue)")
    }

    private func handleStartupDeadline() {
        guard isRecording else { return }
        let captureSnapshot = captureSnapshot()
        guard captureSnapshot.tapCallbackCount == 0 else {
            cancelStartupDeadline(reason: "capture_already_flowing")
            return
        }

        let routeState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: routeState)
        let graphReady = liveGraphReadyDecision()?.shouldInstallTap ?? false

        RecordingDiagnostics.shared.recordRecorderEvent(
            "startup_timeout_no_first_callback",
            detail: "backend=\(activeBackendKind.rawValue) graphReady=\(AppDiagnostics.boolLabel(graphReady)) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint)"
        )
        if activeAttemptMetadata.retryAttempt > 0 && !RecordingStartupGate.retrySuccessGateSatisfied(
            lastObservedRouteChangeMsAgo: RecordingDiagnostics.shared.millisecondsSinceLastRouteChange(),
            graphReady: graphReady,
            firstTapSeen: false
        ) {
            RecordingDiagnostics.shared.recordRetryDecision(
                .retryAbortedGraphStillStale,
                detail: "backend=\(activeBackendKind.rawValue) retryAttempt=\(activeAttemptMetadata.retryAttempt) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint)"
            )
        }

        let reason: RecordingFailureReason = routeState.activeRouteInvolvesBluetooth ? .routeChangedDuringStart : .captureStalled
        forceReset(reason: "startup timeout without first capture callback")
        onRecordingFailed?(
            RecordingFailureEvent(
                reason: reason,
                userMessage: reason.defaultUserMessage,
                framesWritten: captureSnapshot.framesWritten,
                droppedFrames: _droppedFrames.withLock { $0 },
                routeState: routeState,
                captureSnapshot: captureSnapshot,
                detail: "startup deadline elapsed without first capture callback graphReady=\(AppDiagnostics.boolLabel(graphReady)) backend=\(activeBackendKind.rawValue)"
            )
        )
    }

    private func handleFirstCaptureCallback(sourceFormat: AudioGraphFormatSnapshot, event: String) {
        let routeState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: routeState)
        cancelStartupDeadline(reason: "first_capture_callback")

        if let graphReady = liveGraphReadyDecision() {
            RecordingDiagnostics.shared.recordRecorderEvent(
                event,
                detail: "backend=\(activeBackendKind.rawValue) sourceFormat={\(sourceFormat.description)} readinessReason=\(graphReady.reason.rawValue) \(graphReady.detail)"
            )
        } else {
            RecordingDiagnostics.shared.recordRecorderEvent(
                event,
                detail: "backend=\(activeBackendKind.rawValue) sourceFormat={\(sourceFormat.description)} routeFingerprint=\(routeState.fingerprint)"
            )
        }
    }

    private func liveGraphReadyDecision() -> AudioGraphReadinessDecision? {
        guard activeBackendKind == .audioEngine, let inputNode = audioEngine?.inputNode else {
            return nil
        }

        let formats = currentGraphFormats(for: inputNode)
        return RecordingStartupGate.tapInstallDecision(
            routeInvolvesBluetooth: AudioDeviceDiagnostics.currentRouteState().activeRouteInvolvesBluetooth,
            inputFormat: formats.inputSnapshot,
            outputFormat: formats.outputSnapshot,
            expectedInputSampleRate: Double(AudioDeviceDiagnostics.currentRouteState().defaultInput.nominalHz)
        )
    }

    private typealias GraphFormats = (
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        inputSnapshot: AudioGraphFormatSnapshot,
        outputSnapshot: AudioGraphFormatSnapshot
    )

    private func currentGraphFormats(for inputNode: AVAudioInputNode) -> GraphFormats {
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputFormat = inputNode.outputFormat(forBus: 0)
        return (
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            inputSnapshot: AudioGraphFormatSnapshot(inputFormat),
            outputSnapshot: AudioGraphFormatSnapshot(outputFormat)
        )
    }

    private func recordGraphFormats(
        _ graphFormats: GraphFormats,
        event: String,
        routeState: AudioDeviceDiagnostics.RouteState,
        detail: String
    ) {
        let message = "inputFormat={\(graphFormats.inputSnapshot.description)} outputFormat={\(graphFormats.outputSnapshot.description)} routeFingerprint=\(routeState.fingerprint) \(detail)"
        RecordingDiagnostics.shared.recordRecorderEvent(event, detail: message)
        AppDiagnostics.info(
            .audioRecorder,
            "\(event) context={\(RecordingDiagnostics.shared.contextSnapshot())} \(message)"
        )
    }

    @discardableResult
    private func tryInstallTapIfHardwareFormatReady(
        on inputNode: AVAudioInputNode,
        targetFormat: AVAudioFormat,
        file: AVAudioFile,
        routeState: AudioDeviceDiagnostics.RouteState,
        event: String,
        readyEvent: String,
        staleEvent: String
    ) throws -> AudioGraphReadinessDecision {
        let graphFormats = currentGraphFormats(for: inputNode)
        recordGraphFormats(graphFormats, event: event, routeState: routeState, detail: "backend=\(activeBackendKind.rawValue)")
        let decision = RecordingStartupGate.tapInstallDecision(
            routeInvolvesBluetooth: routeState.activeRouteInvolvesBluetooth,
            inputFormat: graphFormats.inputSnapshot,
            outputFormat: graphFormats.outputSnapshot,
            expectedInputSampleRate: Double(routeState.defaultInput.nominalHz)
        )

        if !decision.shouldInstallTap {
            RecordingDiagnostics.shared.recordRecorderEvent(
                staleEvent,
                detail: "backend=\(activeBackendKind.rawValue) reason=\(decision.reason.rawValue) \(decision.detail)"
            )
            AppDiagnostics.warning(
                .audioRecorder,
                "\(staleEvent) context={\(RecordingDiagnostics.shared.contextSnapshot())} backend=\(activeBackendKind.rawValue) reason=\(decision.reason.rawValue) \(decision.detail)"
            )
            return decision
        }

        guard let converter = AVAudioConverter(from: graphFormats.outputFormat, to: targetFormat) else {
            let detail = "converter creation failed inputFormat={\(graphFormats.outputSnapshot.description)} targetFormat={\(AudioGraphFormatSnapshot(targetFormat).description)}"
            RecordingDiagnostics.shared.recordRecorderEvent("converter_creation_failed", detail: detail)
            AppDiagnostics.error(
                .audioRecorder,
                "recording start failed context={\(RecordingDiagnostics.shared.contextSnapshot())} \(detail)"
            )
            throw AudioRecorderError.converterCreationFailed
        }

        RecordingDiagnostics.shared.recordRecorderEvent(
            "tap_install_requested",
            detail: "backend=\(activeBackendKind.rawValue) inputFormat={\(graphFormats.outputSnapshot.description)} targetFormat={\(AudioGraphFormatSnapshot(targetFormat).description)} converterAvailable=yes"
        )
        installTap(on: inputNode, inputFormat: graphFormats.outputFormat, targetFormat: targetFormat, converter: converter, file: file)
        RecordingDiagnostics.shared.recordRecorderEvent(
            readyEvent,
            detail: "backend=\(activeBackendKind.rawValue) reason=\(decision.reason.rawValue) \(decision.detail)"
        )
        AppDiagnostics.info(
            .audioRecorder,
            "\(readyEvent) context={\(RecordingDiagnostics.shared.contextSnapshot())} backend=\(activeBackendKind.rawValue) reason=\(decision.reason.rawValue) \(decision.detail)"
        )
        return decision
    }

    // MARK: - Tap management

    /// Installs the audio tap on the input node with the given format and converter.
    private func installTap(
        on inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        file: AVAudioFile
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self, file] buffer, _ in
            guard let self, self._isCapturing.withLock({ $0 }) else { return }
            let outFile = file
            let now = ProcessInfo.processInfo.systemUptime
            let firstTapSeen = self._captureStats.withLock { stats -> Bool in
                stats.tapCallbackCount += 1
                stats.buffersReceived += 1
                stats.framesReceivedRaw += Int64(buffer.frameLength)
                stats.largestInputBufferFrames = max(stats.largestInputBufferFrames, Int(buffer.frameLength))
                stats.smallestInputBufferFrames = min(stats.smallestInputBufferFrames, Int(buffer.frameLength))
                if let lastTapUptime = stats.lastTapUptime {
                    stats.callbackIntervalTotalMs += (now - lastTapUptime) * 1000
                    stats.callbackIntervalCount += 1
                }
                let isFirstTap = stats.firstTapUptime == nil
                if isFirstTap {
                    stats.firstTapUptime = now
                }
                stats.lastTapUptime = now
                return isFirstTap
            }
            if firstTapSeen {
                Task { @MainActor in
                    self.handleFirstCaptureCallback(
                        sourceFormat: AudioGraphFormatSnapshot(inputFormat),
                        event: "first_tap_seen"
                    )
                }
            }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else {
                let dropped = self._droppedFrames.withLock { count -> Int64 in
                    count += 1
                    return count
                }
                self._captureStats.withLock { $0.buffersDropped += 1 }
                if dropped % 100 == 1 {
                    Self.logger.warning("Audio frame dropped (\(dropped) total): frameCount=0, inputSR=\(inputFormat.sampleRate)")
                }
                return
            }

            var error: NSError?
            var inputConsumed = false
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .haveData, error == nil {
                do {
                    try outFile.write(from: convertedBuffer)
                    self._framesWritten.withLock { $0 += Int64(convertedBuffer.frameLength) }
                    self._captureStats.withLock { stats in
                        stats.buffersConverted += 1
                        stats.framesConverted += Int64(convertedBuffer.frameLength)
                        stats.lastFrameWriteUptime = now
                        if convertedBuffer.frameLength > 0, stats.firstNonZeroWriteUptime == nil {
                            stats.firstNonZeroWriteUptime = now
                        }
                    }
                } catch {
                    Self.logger.error("Failed to write audio buffer: \(error.localizedDescription)")
                }
            } else if let error {
                self._captureStats.withLock { $0.buffersDropped += 1 }
                AppDiagnostics.warning(
                    .audioRecorder,
                    "audio conversion failed session=\(self.recordingSessionID ?? "none") status=\(status.rawValue) error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
                )
            }
        }
    }

    /// Hardware config changed (Bluetooth HFP settle, device disconnect, etc.).
    ///
    /// Two cases:
    ///   - Bluetooth route involved: force a clean reset and let AppState retry with a
    ///     fresh engine after the route settles.
    ///   - No Bluetooth route involved: keep the older in-place tap reinstall path.
    private func handleConfigurationChange() {
        guard isRecording else { return }
        guard activeBackendKind == .audioEngine else {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "config_change_ignored_for_capture_backend",
                detail: "backend=\(activeBackendKind.rawValue)"
            )
            return
        }
        guard let engine = audioEngine else {
            AppDiagnostics.info(
                .audioRecorder,
                "config change ignored session=\(recordingSessionID ?? "none") — engine already torn down"
            )
            return
        }

        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }
        let elapsed = elapsedRecordingTime()
        let previousFingerprint = lastLoggedRouteFingerprint
        let previousRouteState = lastKnownRouteState
        let currentRouteState = AudioDeviceDiagnostics.currentRouteState()
        updateRouteTracking(with: currentRouteState)
        let captureSnapshot = captureSnapshot()
        let inferredReason: RecordingFailureReason =
            currentRouteState.activeRouteInvolvesBluetooth ? .bluetoothHFPRenegotiation : .engineConfigurationChangedEngineStopped
        let graphFormats = currentGraphFormats(for: engine.inputNode)
        recordGraphFormats(
            graphFormats,
            event: "config_change_graph_formats_observed",
            routeState: currentRouteState,
            detail: "backend=\(activeBackendKind.rawValue)"
        )
        RecordingDiagnostics.shared.recordRecorderEvent(
            "engine_configuration_change_received",
            detail: "backend=\(activeBackendKind.rawValue) engineRunning=\(AppDiagnostics.boolLabel(engine.isRunning)) capture={\(captureSnapshot.snapshot)}"
        )
        AppDiagnostics.warning(
            .audioRecorder,
            "config change received context={\(RecordingDiagnostics.shared.contextSnapshot())} engineRunning=\(engine.isRunning) elapsed=\(elapsed) frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} previousRouteFingerprint=\(previousFingerprint) currentRouteFingerprint=\(currentRouteState.fingerprint) transition=\(AudioDeviceDiagnostics.routeTransitionSummary(from: previousRouteState, to: currentRouteState)) activeInput={\(currentRouteState.defaultInput.snapshot)} activeOutput={\(currentRouteState.defaultOutput.snapshot)} route=\(currentRouteState.routeSnapshot) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )

        if engine.isRunning {
            guard let targetFormat = activeTargetFormat, let file = outputFile else {
                AppDiagnostics.warning(
                    .audioRecorder,
                    "config change running session=\(recordingSessionID ?? "none") missing target format or file — cannot reinstall tap"
                )
                return
            }

            let inputNode = engine.inputNode

            // Remove the old (now-dead) tap
            inputNode.removeTap(onBus: 0)

            do {
                let decision = try tryInstallTapIfHardwareFormatReady(
                    on: inputNode,
                    targetFormat: targetFormat,
                    file: file,
                    routeState: currentRouteState,
                    event: "config_change_graph_formats_observed",
                    readyEvent: "config_change_graph_ready",
                    staleEvent: "config_change_graph_stale"
                )
                if decision.shouldInstallTap {
                    AppDiagnostics.info(
                        .audioRecorder,
                        "config change tap reinstalled context={\(RecordingDiagnostics.shared.contextSnapshot())} backend=\(activeBackendKind.rawValue) reason=\(decision.reason.rawValue) \(decision.detail)"
                    )
                }
            } catch {
                AppDiagnostics.error(
                    .audioRecorder,
                    "config change converter creation failed context={\(RecordingDiagnostics.shared.contextSnapshot())} error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
                )
                forceReset(reason: "config change converter creation failed")
                onRecordingFailed?(
                    RecordingFailureEvent(
                        reason: .converterCreationFailed,
                        userMessage: RecordingFailureReason.converterCreationFailed.defaultUserMessage,
                        framesWritten: frames,
                        droppedFrames: dropped,
                        routeState: currentRouteState,
                        captureSnapshot: captureSnapshot,
                        detail: "config change failed to reinstall tap error=\(error.localizedDescription)"
                    )
                )
            }
            return
        }

        // Engine stopped by the system (HFP negotiate, device disconnect, etc.)
        AppDiagnostics.warning(
            .audioRecorder,
            "config change engine stopped context={\(RecordingDiagnostics.shared.contextSnapshot())} — force resetting for reconnect"
        )
        forceReset(reason: "config change while engine stopped")
        onRecordingFailed?(
            RecordingFailureEvent(
                reason: inferredReason,
                userMessage: inferredReason.defaultUserMessage,
                framesWritten: frames,
                droppedFrames: dropped,
                routeState: currentRouteState,
                captureSnapshot: captureSnapshot,
                detail: "engine stopped unexpectedly transition=\(AudioDeviceDiagnostics.routeTransitionSummary(from: previousRouteState, to: currentRouteState))"
            )
        )
    }

    // MARK: - Lifecycle

    /// Delay ARC deallocation after an engine stop/system stop. Releasing immediately can
    /// crash if CoreAudio still has in-flight blocks on its internal dispatch queues.
    private func releaseEngineWithZombieDelay(_ engine: AVAudioEngine?) {
        guard let engine else {
            audioEngine = nil
            return
        }

        let zombie = engine
        audioEngine = nil
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            _ = zombie
        }
    }

    func stopRecording() -> (url: URL, duration: TimeInterval, framesWritten: Int64, forensics: RecordingSessionForensics)? {
        guard isRecording, let url = outputURL else { return nil }
        let captureSnapshot = captureSnapshot()

        _isCapturing.withLock { $0 = false }
        isRecording = false

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
            RecordingDiagnostics.shared.recordRecorderEvent("config_observer_detached", detail: "observerInstalled=no")
        }

        durationTimer?.invalidate()
        durationTimer = nil

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil
        startupDeadlineTimer?.invalidate()
        startupDeadlineTimer = nil
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

        switch activeBackendKind {
        case .audioEngine:
            if let engine = audioEngine {
                if engine.isRunning {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
                releaseEngineWithZombieDelay(engine)
            } else {
                audioEngine = nil
            }
        case .captureSession:
            captureSessionRecorder?.stop()
            captureSessionRecorder = nil
            audioEngine = nil
        }
        outputFile = nil
        recordingStartTime = nil
        engineStartUptime = nil
        activeTargetFormat = nil
        activeRouteInvolvesBluetooth = false
        leaveRoutingArbitrationIfNeeded()

        AppDiagnostics.info(
            .audioRecorder,
            "recording stopped context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["backend": activeBackendKind.rawValue]))} duration=\(String(format: "%.3f", duration))s frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} file=\(url.lastPathComponent) routeAtStartFingerprint=\(routeFingerprintAtStart) routeAtStopFingerprint=\(stopRouteState.fingerprint) routeChangedDuringSession=\(AppDiagnostics.boolLabel(sessionObservedRouteChange)) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(sessionObservedCaptureStall)) lastKnownInput={\(lastKnownInputSnapshot)} lastKnownOutput={\(lastKnownOutputSnapshot)} route=\(stopRouteState.routeSnapshot) fileExists=\(AppDiagnostics.boolLabel(FileManager.default.fileExists(atPath: url.path)))"
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
        activeBackendKind = .audioEngine
        RecordingDiagnostics.shared.clearAttemptContext()

        return (url, duration, frames, forensics)
    }

    /// Unconditionally resets all recording state. Does NOT return the recording.
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
            "force reset context={\(RecordingDiagnostics.shared.contextSnapshot())} session=\(sessionID) reason=\(reason) elapsed=\(elapsedRecordingTime()) frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} route=\(AudioDeviceDiagnostics.currentRouteSnapshot()) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        _isCapturing.withLock { $0 = false }

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
            RecordingDiagnostics.shared.recordRecorderEvent("config_observer_detached", detail: "observerInstalled=no")
        }

        durationTimer?.invalidate()
        durationTimer = nil

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil
        startupDeadlineTimer?.invalidate()
        startupDeadlineTimer = nil
        RecordingDiagnostics.shared.recordRecorderEvent("timers_detached", detail: "heartbeatTimer=no durationTimer=no watchdog=no")

        switch activeBackendKind {
        case .audioEngine:
            if let engine = audioEngine {
                if engine.isRunning {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
                releaseEngineWithZombieDelay(engine)
            } else {
                audioEngine = nil
            }
        case .captureSession:
            captureSessionRecorder?.forceReset()
            captureSessionRecorder = nil
            audioEngine = nil
        }
        outputFile = nil
        recordingStartTime = nil
        engineStartUptime = nil
        activeTargetFormat = nil
        activeRouteInvolvesBluetooth = false
        leaveRoutingArbitrationIfNeeded()
        isRecording = false
        recordingDuration = 0
        recordingSessionID = nil
        activeAttemptMetadata = .userHotkey
        activeBackendKind = .audioEngine
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
        self._isCapturing.withLock { $0 = false }
        if let observer = self.configObserver {
            NotificationCenter.default.removeObserver(observer)
            self.configObserver = nil
        }
        self.audioEngine = nil
        self.outputFile = nil
        self.outputURL = nil
        self.activeTargetFormat = nil
        self.activeRouteInvolvesBluetooth = false
        self.isRecording = false
        self.recordingDuration = 0
        self.recordingStartTime = nil
        self.engineStartUptime = nil
        self.captureSessionRecorder?.forceReset()
        self.captureSessionRecorder = nil
        self.recordingSessionID = nil
        self.durationTimer?.invalidate()
        self.durationTimer = nil
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
        self.noAudioWatchdog?.invalidate()
        self.noAudioWatchdog = nil
        self.startupDeadlineTimer?.invalidate()
        self.startupDeadlineTimer = nil
        self.leaveRoutingArbitrationIfNeeded()
        self.activeAttemptMetadata = .userHotkey
        self.activeBackendKind = .audioEngine
        resetSessionForensics()
        RecordingDiagnostics.shared.clearAttemptContext()
        try? FileManager.default.removeItem(at: fileURL)
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
                "watchdog fired context={\(RecordingDiagnostics.shared.contextSnapshot())} frames=\(frames) dropped=\(_droppedFrames.withLock { $0 }) elapsed=\(elapsedRecordingTime()) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(sessionObservedCaptureStall)) lastKnownInput={\(lastKnownInputSnapshot)} lastKnownOutput={\(lastKnownOutputSnapshot)} route=\(routeState.routeSnapshot)"
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
                "watchdog healthy context={\(RecordingDiagnostics.shared.contextSnapshot())} frames=\(frames) dropped=\(_droppedFrames.withLock { $0 }) elapsed=\(elapsedRecordingTime()) capture={\(captureSnapshot.snapshot)}"
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
        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }
        let delta = frames - lastHeartbeatFramesWritten
        lastHeartbeatFramesWritten = frames
        let captureStalled = delta <= 0
        if captureStalled {
            sessionObservedCaptureStall = true
        }

        let routeState = AudioDeviceDiagnostics.currentRouteState()
        let previousFingerprint = lastLoggedRouteFingerprint
        updateRouteTracking(with: routeState)
        let captureSnapshot = captureSnapshot()
        let lastRouteChangeMs = RecordingDiagnostics.shared.millisecondsSinceLastRouteChange()

        let baseMessage =
            "recording heartbeat context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["captureState": captureSnapshot.captureState, "lastObservedRouteChangeMsAgo": String(lastRouteChangeMs), "backend": activeBackendKind.rawValue]))} elapsed=\(elapsedRecordingTime()) engineRunning=\(AppDiagnostics.boolLabel(audioEngine?.isRunning ?? false)) frames=\(frames) dropped=\(dropped) deltaFrames=\(delta) captureStalled=\(AppDiagnostics.boolLabel(captureStalled)) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint) activeInput={\(routeState.defaultInput.snapshot)} activeOutput={\(routeState.defaultOutput.snapshot)} bluetoothInput=\(AppDiagnostics.boolLabel(routeState.defaultInputIsBluetooth)) bluetoothOutput=\(AppDiagnostics.boolLabel(routeState.defaultOutputIsBluetooth)) bluetoothRoute=\(AppDiagnostics.boolLabel(routeState.activeRouteInvolvesBluetooth))"

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
        engineStartUptime = nil
        _captureStats.withLock { $0 = RealtimeCaptureStats() }
    }

    private static func describe(format: AVAudioFormat) -> String {
        let sampleRate = String(format: "%.1f", format.sampleRate)
        return "\(sampleRate)Hz/\(format.channelCount)ch/commonFormat=\(format.commonFormat.rawValue)"
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
        let firstTapMs = msSinceEngineStart(stats.firstTapUptime)
        let firstWriteMs = msSinceEngineStart(stats.firstNonZeroWriteUptime)
        let lastTapAgo = msAgo(stats.lastTapUptime, now: now)
        let firstTapAgo = msAgo(stats.firstTapUptime, now: now)
        let lastWriteAgo = msAgo(stats.lastFrameWriteUptime, now: now)
        let framesWritten = _framesWritten.withLock { $0 }

        let captureState: String
        if tapCallbacks == 0 {
            captureState = "never_started"
        } else if framesWritten == 0 {
            captureState = "warming_up"
        } else if lastTapAgo != nil, let lastTapAgo, lastTapAgo > 1000 {
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

    private func msSinceEngineStart(_ uptime: TimeInterval?) -> Int? {
        guard let uptime, let engineStartUptime else { return nil }
        return Int((uptime - engineStartUptime) * 1000)
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
    case captureSessionConfigurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create target audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .captureDeviceUnavailable:
            return "No microphone device is available for AVCaptureSession"
        case .captureSessionConfigurationFailed(let detail):
            return detail
        }
    }
}
