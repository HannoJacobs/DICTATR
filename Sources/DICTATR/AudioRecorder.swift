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
// BLUETOOTH HFP HANDLING (v1.15):
//   Bluetooth headphones switch from A2DP to HFP when mic input is activated by
//   engine.start(). The format looks valid (44100Hz A2DP) before start, so we can't
//   detect HFP in advance. Two things happen:
//
//   1. Engine gets killed by CoreAudio during HFP negotiate (~168ms after start).
//      This is unavoidable. AppState's retry handles it.
//
//   2. On retry, the Bluetooth route may keep renegotiating underneath the engine.
//      Reinstalling the tap in that intermediate state can trip AVAudioEngine format
//      assertions. Fix: reset the recorder and let AppState restart with a fresh
//      engine after the route settles, while staying on the current system route.

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

private struct RealtimeCaptureStats {
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
        let attemptContext = RecordingDiagnostics.shared.beginAttempt(recordingSessionID: sessionID, metadata: metadata)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictatr_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)
        let startRouteState = AudioDeviceDiagnostics.currentRouteState()
        _captureStats.withLock { $0 = RealtimeCaptureStats() }

        AppDiagnostics.info(
            .audioRecorder,
            "recording start requested context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["trigger": metadata.trigger, "retryAttempt": String(metadata.retryAttempt), "attempt": attemptContext.attemptID, "engineID": attemptContext.engineInstanceID]))} outputFile=\(fileURL.lastPathComponent) routeFingerprint=\(startRouteState.fingerprint) activeInput={\(startRouteState.defaultInput.snapshot)} activeOutput={\(startRouteState.defaultOutput.snapshot)} route=\(startRouteState.routeSnapshot) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        RecordingDiagnostics.shared.recordRecorderEvent(
            "engine_created",
            detail: "trigger=\(metadata.trigger) retryAttempt=\(metadata.retryAttempt) file=\(fileURL.lastPathComponent)"
        )

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let inputFormat = inputNode.outputFormat(forBus: 0)
        RecordingDiagnostics.shared.recordRecorderEvent(
            "input_format_inspected",
            detail: "inputFormat={\(Self.describe(format: inputFormat))} bluetoothRoute=\(AppDiagnostics.boolLabel(startRouteState.activeRouteInvolvesBluetooth))"
        )
        AppDiagnostics.info(
            .audioRecorder,
            "recording start preflight context={\(RecordingDiagnostics.shared.contextSnapshot())} inputFormat={\(Self.describe(format: inputFormat))} currentDefaultInput={\(startRouteState.defaultInput.snapshot)} currentDefaultOutput={\(startRouteState.defaultOutput.snapshot)} bluetoothRoute=\(AppDiagnostics.boolLabel(startRouteState.activeRouteInvolvesBluetooth))"
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

        self.audioEngine = engine
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

        let formatValid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
        if formatValid {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                let detail = "converter creation failed inputFormat={\(Self.describe(format: inputFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
                RecordingDiagnostics.shared.recordRecorderEvent("converter_creation_failed", detail: detail)
                AppDiagnostics.error(
                    .audioRecorder,
                    "recording start failed context={\(RecordingDiagnostics.shared.contextSnapshot())} \(detail)"
                )
                cleanupAfterFailedStart(fileURL: fileURL)
                throw AudioRecorderError.converterCreationFailed
            }
            RecordingDiagnostics.shared.recordRecorderEvent(
                "tap_install_requested",
                detail: "inputFormat={\(Self.describe(format: inputFormat))} targetFormat={\(Self.describe(format: targetFormat))} converterAvailable=yes"
            )
            installTap(on: inputNode, inputFormat: inputFormat, targetFormat: targetFormat, converter: converter, file: file)
            RecordingDiagnostics.shared.recordRecorderEvent(
                "tap_install_succeeded",
                detail: "inputFormat={\(Self.describe(format: inputFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
            )
            AppDiagnostics.info(
                .audioRecorder,
                "recording start installed tap context={\(RecordingDiagnostics.shared.contextSnapshot())} inputFormat={\(Self.describe(format: inputFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
            )
        } else {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "input_format_invalid",
                detail: "inputFormat={\(Self.describe(format: inputFormat))}"
            )
            AppDiagnostics.warning(
                .audioRecorder,
                "recording start input format not ready context={\(RecordingDiagnostics.shared.contextSnapshot())} inputFormat={\(Self.describe(format: inputFormat))} — waiting for config change"
            )
        }

        do {
            RecordingDiagnostics.shared.noteEngineStartRequested()
            try engine.start()
            self.engineStartUptime = ProcessInfo.processInfo.systemUptime
            RecordingDiagnostics.shared.noteEngineStarted()
            let engineStartedRouteState = AudioDeviceDiagnostics.currentRouteState()
            updateRouteTracking(with: engineStartedRouteState)
            AppDiagnostics.info(
                .audioRecorder,
                "engine started context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["tapInstalled": AppDiagnostics.boolLabel(formatValid)]))} file=\(fileURL.lastPathComponent) routeFingerprintAtStart=\(routeFingerprintAtStart) routeFingerprintAtEngineStart=\(engineStartedRouteState.fingerprint) routeChangedBeforeEngineStart=\(AppDiagnostics.boolLabel(routeFingerprintAtStart != engineStartedRouteState.fingerprint)) activeInput={\(engineStartedRouteState.defaultInput.snapshot)} activeOutput={\(engineStartedRouteState.defaultOutput.snapshot)} route=\(engineStartedRouteState.routeSnapshot)"
            )
        } catch {
            RecordingDiagnostics.shared.recordRecorderEvent(
                "engine_start_failed",
                detail: "error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))}"
            )
            AppDiagnostics.error(
                .audioRecorder,
                "engine failed to start context={\(RecordingDiagnostics.shared.contextSnapshot())} error={\(AppDiagnostics.compactText(Self.describe(error: error), limit: 500))} route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            if formatValid { inputNode.removeTap(onBus: 0) }
            cleanupAfterFailedStart(fileURL: fileURL)
            throw error
        }

        // Observe audio configuration changes. Bluetooth route churn now forces a clean
        // restart instead of trying to mutate a live engine through format renegotiation.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
        RecordingDiagnostics.shared.recordRecorderEvent(
            "config_observer_attached",
            detail: "observerInstalled=yes"
        )

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

        // Watchdog: if recording for 5s with essentially no audio, auto-stop and report.
        noAudioWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkNoAudioWatchdog()
            }
        }

        return fileURL
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
            self._captureStats.withLock { stats in
                stats.tapCallbackCount += 1
                stats.buffersReceived += 1
                stats.framesReceivedRaw += Int64(buffer.frameLength)
                stats.largestInputBufferFrames = max(stats.largestInputBufferFrames, Int(buffer.frameLength))
                stats.smallestInputBufferFrames = min(stats.smallestInputBufferFrames, Int(buffer.frameLength))
                if let lastTapUptime = stats.lastTapUptime {
                    stats.callbackIntervalTotalMs += (now - lastTapUptime) * 1000
                    stats.callbackIntervalCount += 1
                }
                if stats.firstTapUptime == nil {
                    stats.firstTapUptime = now
                }
                stats.lastTapUptime = now
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
        RecordingDiagnostics.shared.recordRecorderEvent(
            "engine_configuration_change_received",
            detail: "engineRunning=\(AppDiagnostics.boolLabel(engine.isRunning)) capture={\(captureSnapshot.snapshot)}"
        )
        AppDiagnostics.warning(
            .audioRecorder,
            "config change received context={\(RecordingDiagnostics.shared.contextSnapshot())} engineRunning=\(engine.isRunning) elapsed=\(elapsed) frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} previousRouteFingerprint=\(previousFingerprint) currentRouteFingerprint=\(currentRouteState.fingerprint) transition=\(AudioDeviceDiagnostics.routeTransitionSummary(from: previousRouteState, to: currentRouteState)) activeInput={\(currentRouteState.defaultInput.snapshot)} activeOutput={\(currentRouteState.defaultOutput.snapshot)} route=\(currentRouteState.routeSnapshot) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )

        let routeInvolvesBluetooth = activeRouteInvolvesBluetooth || currentRouteState.activeRouteInvolvesBluetooth

        if routeInvolvesBluetooth {
            AppDiagnostics.warning(
                .audioRecorder,
                "config change forcing clean restart context={\(RecordingDiagnostics.shared.contextSnapshot())} engineRunning=\(engine.isRunning) bluetoothRoute=true elapsed=\(elapsed) frames=\(frames) dropped=\(dropped)"
            )
            forceReset(reason: engine.isRunning ? "config change during bluetooth route churn" : "config change stopped engine during bluetooth route churn")
            onRecordingFailed?(
                RecordingFailureEvent(
                    reason: inferredReason,
                    userMessage: inferredReason.defaultUserMessage,
                    framesWritten: frames,
                    droppedFrames: dropped,
                    routeState: currentRouteState,
                    captureSnapshot: captureSnapshot,
                    detail: "previousRouteFingerprint=\(previousFingerprint) currentRouteFingerprint=\(currentRouteState.fingerprint) transition=\(AudioDeviceDiagnostics.routeTransitionSummary(from: previousRouteState, to: currentRouteState))"
                )
            )
            return
        }

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

            let newFormat = inputNode.outputFormat(forBus: 0)
            if newFormat.sampleRate > 0 && newFormat.channelCount > 0 {
                if let converter = AVAudioConverter(from: newFormat, to: targetFormat) {
                    installTap(on: inputNode, inputFormat: newFormat, targetFormat: targetFormat, converter: converter, file: file)
                    RecordingDiagnostics.shared.recordRecorderEvent(
                        "tap_reinstalled",
                        detail: "newInputFormat={\(Self.describe(format: newFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
                    )
                    AppDiagnostics.info(
                        .audioRecorder,
                        "config change tap reinstalled context={\(RecordingDiagnostics.shared.contextSnapshot())} newInputFormat={\(Self.describe(format: newFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
                    )
                } else {
                    AppDiagnostics.warning(
                        .audioRecorder,
                        "config change converter creation failed context={\(RecordingDiagnostics.shared.contextSnapshot())} newInputFormat={\(Self.describe(format: newFormat))}"
                    )
                }
            } else {
                AppDiagnostics.warning(
                    .audioRecorder,
                    "config change format still invalid context={\(RecordingDiagnostics.shared.contextSnapshot())} newInputFormat={\(Self.describe(format: newFormat))} — waiting for next change"
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

        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            releaseEngineWithZombieDelay(engine)
        } else {
            audioEngine = nil
        }
        outputFile = nil
        recordingStartTime = nil
        engineStartUptime = nil
        activeTargetFormat = nil
        activeRouteInvolvesBluetooth = false

        AppDiagnostics.info(
            .audioRecorder,
            "recording stopped context={\(RecordingDiagnostics.shared.contextSnapshot())} duration=\(String(format: "%.3f", duration))s frames=\(frames) dropped=\(dropped) capture={\(captureSnapshot.snapshot)} file=\(url.lastPathComponent) routeAtStartFingerprint=\(routeFingerprintAtStart) routeAtStopFingerprint=\(stopRouteState.fingerprint) routeChangedDuringSession=\(AppDiagnostics.boolLabel(sessionObservedRouteChange)) stalledHeartbeatObserved=\(AppDiagnostics.boolLabel(sessionObservedCaptureStall)) lastKnownInput={\(lastKnownInputSnapshot)} lastKnownOutput={\(lastKnownOutputSnapshot)} route=\(stopRouteState.routeSnapshot) fileExists=\(AppDiagnostics.boolLabel(FileManager.default.fileExists(atPath: url.path)))"
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
        RecordingDiagnostics.shared.recordRecorderEvent("timers_detached", detail: "heartbeatTimer=no durationTimer=no watchdog=no")

        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            releaseEngineWithZombieDelay(engine)
        } else {
            audioEngine = nil
        }
        outputFile = nil
        recordingStartTime = nil
        engineStartUptime = nil
        activeTargetFormat = nil
        activeRouteInvolvesBluetooth = false
        isRecording = false
        recordingDuration = 0
        recordingSessionID = nil
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
        self.audioEngine = nil
        self.outputFile = nil
        self.outputURL = nil
        self.activeTargetFormat = nil
        self.activeRouteInvolvesBluetooth = false
        self.isRecording = false
        self.recordingDuration = 0
        self.recordingStartTime = nil
        self.engineStartUptime = nil
        self.recordingSessionID = nil
        self.heartbeatTimer?.invalidate()
        self.heartbeatTimer = nil
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
            "recording heartbeat context={\(RecordingDiagnostics.shared.contextSnapshot(extra: ["captureState": captureSnapshot.captureState, "lastObservedRouteChangeMsAgo": String(lastRouteChangeMs)]))} elapsed=\(elapsedRecordingTime()) engineRunning=\(AppDiagnostics.boolLabel(audioEngine?.isRunning ?? false)) frames=\(frames) dropped=\(dropped) deltaFrames=\(delta) captureStalled=\(AppDiagnostics.boolLabel(captureStalled)) capture={\(captureSnapshot.snapshot)} routeFingerprint=\(routeState.fingerprint) activeInput={\(routeState.defaultInput.snapshot)} activeOutput={\(routeState.defaultOutput.snapshot)} bluetoothInput=\(AppDiagnostics.boolLabel(routeState.defaultInputIsBluetooth)) bluetoothOutput=\(AppDiagnostics.boolLabel(routeState.defaultOutputIsBluetooth)) bluetoothRoute=\(AppDiagnostics.boolLabel(routeState.activeRouteInvolvesBluetooth))"

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

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create target audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        }
    }
}
