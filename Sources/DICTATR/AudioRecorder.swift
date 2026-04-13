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
    private var durationTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var noAudioWatchdog: Timer?

    /// Stored for tap reinstallation after config changes.
    private var activeTargetFormat: AVAudioFormat?
    private var activeRouteInvolvesBluetooth = false

    var onRecordingFailed: ((String) -> Void)?
    var onRecordingStable: (() -> Void)?

    // Thread-safe flags readable from the real-time audio thread.
    private let _isCapturing = OSAllocatedUnfairLock(initialState: false)
    private let _framesWritten = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _droppedFrames = OSAllocatedUnfairLock(initialState: Int64(0))

    func startRecording() throws -> URL {
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
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictatr_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        AppDiagnostics.info(
            .audioRecorder,
            "recording start requested session=\(sessionID) outputFile=\(fileURL.lastPathComponent) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let inputFormat = inputNode.outputFormat(forBus: 0)
        AppDiagnostics.info(
            .audioRecorder,
            "recording start preflight session=\(sessionID) inputFormat={\(Self.describe(format: inputFormat))}"
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
        self.activeRouteInvolvesBluetooth = AudioDeviceDiagnostics.activeRouteInvolvesBluetooth()
        self._isCapturing.withLock { $0 = true }
        self._framesWritten.withLock { $0 = 0 }
        self._droppedFrames.withLock { $0 = 0 }
        self.isRecording = true
        self.recordingDuration = 0
        self.recordingStartTime = ProcessInfo.processInfo.systemUptime

        let formatValid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
        if formatValid {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                AppDiagnostics.error(
                    .audioRecorder,
                    "recording start failed session=\(sessionID) converter creation failed inputFormat={\(Self.describe(format: inputFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
                )
                cleanupAfterFailedStart(fileURL: fileURL)
                throw AudioRecorderError.converterCreationFailed
            }
            installTap(on: inputNode, inputFormat: inputFormat, targetFormat: targetFormat, converter: converter, file: file)
            AppDiagnostics.info(
                .audioRecorder,
                "recording start installed tap session=\(sessionID) inputFormat={\(Self.describe(format: inputFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
            )
        } else {
            AppDiagnostics.warning(
                .audioRecorder,
                "recording start input format not ready session=\(sessionID) inputFormat={\(Self.describe(format: inputFormat))} — waiting for config change"
            )
        }

        do {
            try engine.start()
            AppDiagnostics.info(
                .audioRecorder,
                "engine started session=\(sessionID) tapInstalled=\(formatValid) file=\(fileURL.lastPathComponent) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
        } catch {
            AppDiagnostics.error(
                .audioRecorder,
                "engine failed to start session=\(sessionID) error=\(error.localizedDescription) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
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

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = ProcessInfo.processInfo.systemUptime - start
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
                } catch {
                    Self.logger.error("Failed to write audio buffer: \(error.localizedDescription)")
                }
            } else if let error {
                AppDiagnostics.warning(
                    .audioRecorder,
                    "audio conversion failed session=\(self.recordingSessionID ?? "none") status=\(status.rawValue) error=\(error.localizedDescription)"
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
        AppDiagnostics.warning(
            .audioRecorder,
            "config change received session=\(recordingSessionID ?? "none") engineRunning=\(engine.isRunning) elapsed=\(elapsed) frames=\(frames) dropped=\(dropped) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )

        let routeInvolvesBluetooth = activeRouteInvolvesBluetooth || AudioDeviceDiagnostics.activeRouteInvolvesBluetooth()

        if routeInvolvesBluetooth {
            AppDiagnostics.warning(
                .audioRecorder,
                "config change forcing clean restart session=\(recordingSessionID ?? "none") engineRunning=\(engine.isRunning) bluetoothRoute=true elapsed=\(elapsed) frames=\(frames) dropped=\(dropped)"
            )
            forceReset(reason: engine.isRunning ? "config change during bluetooth route churn" : "config change stopped engine during bluetooth route churn")
            onRecordingFailed?("Audio device changed. Reconnecting...")
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
                    AppDiagnostics.info(
                        .audioRecorder,
                        "config change tap reinstalled session=\(recordingSessionID ?? "none") newInputFormat={\(Self.describe(format: newFormat))} targetFormat={\(Self.describe(format: targetFormat))}"
                    )
                } else {
                    AppDiagnostics.warning(
                        .audioRecorder,
                        "config change converter creation failed session=\(recordingSessionID ?? "none") newInputFormat={\(Self.describe(format: newFormat))}"
                    )
                }
            } else {
                AppDiagnostics.warning(
                    .audioRecorder,
                    "config change format still invalid session=\(recordingSessionID ?? "none") newInputFormat={\(Self.describe(format: newFormat))} — waiting for next change"
                )
            }
            return
        }

        // Engine stopped by the system (HFP negotiate, device disconnect, etc.)
        AppDiagnostics.warning(
            .audioRecorder,
            "config change engine stopped session=\(recordingSessionID ?? "none") — force resetting for reconnect"
        )
        forceReset(reason: "config change while engine stopped")
        onRecordingFailed?("Audio device changed. Reconnecting...")
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

    func stopRecording() -> (url: URL, duration: TimeInterval, framesWritten: Int64)? {
        guard isRecording, let url = outputURL else { return nil }
        let sessionID = recordingSessionID ?? "none"

        _isCapturing.withLock { $0 = false }
        isRecording = false

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        durationTimer?.invalidate()
        durationTimer = nil

        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil

        let duration: TimeInterval
        if let start = recordingStartTime {
            duration = ProcessInfo.processInfo.systemUptime - start
        } else {
            duration = recordingDuration
        }

        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }

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
        activeTargetFormat = nil
        activeRouteInvolvesBluetooth = false

        AppDiagnostics.info(
            .audioRecorder,
            "recording stopped session=\(sessionID) duration=\(String(format: "%.3f", duration))s frames=\(frames) dropped=\(dropped) file=\(url.lastPathComponent) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
        recordingSessionID = nil

        return (url, duration, frames)
    }

    /// Unconditionally resets all recording state. Does NOT return the recording.
    func forceReset(reason: String = "unspecified") {
        let sessionID = recordingSessionID ?? "none"
        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }
        AppDiagnostics.warning(
            .audioRecorder,
            "force reset session=\(sessionID) reason=\(reason) elapsed=\(elapsedRecordingTime()) frames=\(frames) dropped=\(dropped) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
        _isCapturing.withLock { $0 = false }

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        durationTimer?.invalidate()
        durationTimer = nil

        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil

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
        activeTargetFormat = nil
        activeRouteInvolvesBluetooth = false
        isRecording = false
        recordingDuration = 0
        recordingSessionID = nil

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
        }
    }

    private func cleanupAfterFailedStart(fileURL: URL) {
        AppDiagnostics.warning(
            .audioRecorder,
            "cleanup after failed start session=\(recordingSessionID ?? "none") file=\(fileURL.lastPathComponent)"
        )
        self._isCapturing.withLock { $0 = false }
        self.audioEngine = nil
        self.outputFile = nil
        self.outputURL = nil
        self.activeTargetFormat = nil
        self.activeRouteInvolvesBluetooth = false
        self.isRecording = false
        self.recordingDuration = 0
        self.recordingStartTime = nil
        self.recordingSessionID = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func checkNoAudioWatchdog() {
        guard isRecording else { return }
        let frames = _framesWritten.withLock { $0 }
        if frames < 800 {
            AppDiagnostics.error(
                .audioRecorder,
                "watchdog fired session=\(recordingSessionID ?? "none") frames=\(frames) dropped=\(_droppedFrames.withLock { $0 }) elapsed=\(elapsedRecordingTime()) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            let message = "No audio captured after 5 seconds. Check your microphone or try reconnecting your headphones."
            forceReset(reason: "watchdog no audio after 5 seconds")
            onRecordingFailed?(message)
        } else {
            AppDiagnostics.info(
                .audioRecorder,
                "watchdog healthy session=\(recordingSessionID ?? "none") frames=\(frames) dropped=\(_droppedFrames.withLock { $0 }) elapsed=\(elapsedRecordingTime())"
            )
            onRecordingStable?()
        }
    }

    private func elapsedRecordingTime() -> String {
        guard let start = recordingStartTime else { return "unknown" }
        return String(format: "%.3fs", ProcessInfo.processInfo.systemUptime - start)
    }

    private static func describe(format: AVAudioFormat) -> String {
        let sampleRate = String(format: "%.1f", format.sampleRate)
        return "\(sampleRate)Hz/\(format.channelCount)ch/commonFormat=\(format.commonFormat.rawValue)"
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
