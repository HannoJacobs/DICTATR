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

import AVFoundation
import CoreAudio
import Foundation
import os

@Observable
@MainActor
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var recordingDuration: TimeInterval = 0

    private static let logger = Logger(subsystem: "com.dictatr", category: "AudioRecorder")

    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingStartTime: TimeInterval?
    private var durationTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var noAudioWatchdog: Timer?
    var onRecordingFailed: ((String) -> Void)?
    var onRecordingStable: (() -> Void)?

    // Thread-safe flags readable from the real-time audio thread.
    // @Observable's isRecording is not safe to read from the audio thread.
    // OSAllocatedUnfairLock provides proper atomicity for cross-thread access.
    private let _isCapturing = OSAllocatedUnfairLock(initialState: false)
    private let _framesWritten = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _droppedFrames = OSAllocatedUnfairLock(initialState: Int64(0))

    /// If true, the next startRecording() will force the built-in microphone
    /// instead of the system default (which may be stuck Bluetooth).
    var useBuiltInMic = false

    func startRecording() throws -> URL {
        // Guard against double-start — clean up any existing session first
        if isRecording {
            Self.logger.warning("startRecording() called while already recording — cleaning up previous session")
            if let result = stopRecording() {
                try? FileManager.default.removeItem(at: result.url)
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictatr_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // If Bluetooth is stuck, override the engine's input to the built-in mic.
        if useBuiltInMic, let builtInID = Self.findBuiltInMicDevice(), let audioUnit = inputNode.audioUnit {
            var deviceID = builtInID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                Self.logger.info("Overrode input device to built-in mic (deviceID=\(builtInID))")
            } else {
                Self.logger.warning("Failed to set built-in mic (status=\(status)) — using system default")
            }
        } else if useBuiltInMic {
            Self.logger.warning("Cannot override to built-in mic (audioUnit or device not available) — using system default")
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Bluetooth devices (AirPods, etc.) switch from AAC to HFP codec when the mic
        // activates, which briefly reports sampleRate=0. Instead of blocking with a retry
        // loop, we start immediately and let the configurationChangeNotification handler
        // reinstall the tap once the codec switch completes. Frames are dropped until then,
        // tracked by _droppedFrames, and caught by the framesWritten < 800 check at stop.
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            Self.logger.warning("Input format not ready (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)) — Bluetooth codec switch likely in progress. Will recover via config change handler.")
        } else {
            Self.logger.info("Recording with input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
        }

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

        // Store outputFile before installing tap so closure can access it via self
        self.outputFile = file
        self._isCapturing.withLock { $0 = true }
        self._framesWritten.withLock { $0 = 0 }
        self._droppedFrames.withLock { $0 = 0 }
        // Only install the tap if the input format is valid. When sampleRate is 0
        // (Bluetooth codec switch in progress), skip the tap — the config change
        // handler will install it once the format becomes valid.
        let formatValid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0
        if formatValid {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                self._isCapturing.withLock { $0 = false }
                self.outputFile = nil
                try? FileManager.default.removeItem(at: fileURL)
                throw AudioRecorderError.converterCreationFailed
            }
            installTap(on: inputNode, inputFormat: inputFormat, targetFormat: targetFormat, converter: converter, file: file)
        }

        do {
            try engine.start()
            Self.logger.info("Engine started (tapInstalled=\(formatValid), file=\(fileURL.lastPathComponent))")
        } catch {
            Self.logger.error("Engine failed to start: \(error.localizedDescription)")
            // Clean up the tap, file, and state since engine failed to start
            self._isCapturing.withLock { $0 = false }
            if formatValid { inputNode.removeTap(onBus: 0) }
            self.outputFile = nil
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        self.audioEngine = engine
        self.outputURL = fileURL
        self.isRecording = true
        self.recordingDuration = 0
        self.recordingStartTime = ProcessInfo.processInfo.systemUptime

        // Observe audio configuration changes (device connect/disconnect, Bluetooth profile switch).
        // Some route changes emit AVAudioEngineConfigurationChange even when the freshly started
        // engine is still healthy. handleConfigurationChange() only tears down when the system
        // actually stopped the engine; otherwise it lets recording continue.
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
        // Catches the case where config change never fires (no recovery possible).
        noAudioWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkNoAudioWatchdog()
            }
        }

        return fileURL
    }

    /// Installs the audio tap on the input node with the given format and converter.
    /// Shared by startRecording() (initial install) and handleConfigurationChange() (recovery).
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
                Self.logger.warning("Audio conversion failed: status=\(status.rawValue), error=\(error.localizedDescription)")
            }
        }
    }

    /// Audio config changed (Bluetooth profile switch, device disconnect, etc.).
    /// Some devices emit this notification during startup/route settling without
    /// actually stopping the engine. Only tear down when the engine is no longer
    /// running; otherwise keep recording and let the watchdog catch true no-audio
    /// failures.
    private func handleConfigurationChange() {
        guard isRecording else { return }

        // Debounce: if we already handled a config change, ignore further ones.
        // The forceReset below sets isRecording=false, but the notification can
        // arrive multiple times before the main-actor dispatch processes them all.
        guard let engine = audioEngine else {
            Self.logger.info("Config change ignored — engine already torn down")
            return
        }

        guard !engine.isRunning else {
            Self.logger.info("Config change received but engine is still running — ignoring transient route-settle notification")
            return
        }

        Self.logger.warning("Audio configuration changed during recording and engine stopped — tearing down for fresh start")
        forceReset()
        onRecordingFailed?("Audio device changed. Reconnecting...")
    }

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

        // Signal the tap callback to stop writing BEFORE tearing down the engine.
        // This prevents the tap from writing with invalid buffers after engine stop.
        _isCapturing.withLock { $0 = false }
        isRecording = false

        // Remove config change observer
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        durationTimer?.invalidate()
        durationTimer = nil

        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil

        // Compute final duration from monotonic clock for accuracy (timer is up to 100ms stale)
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

        Self.logger.info("Recording stopped: \(frames) frames written, \(dropped) frames dropped, \(String(format: "%.1f", duration))s duration")

        return (url, duration, frames)
    }

    /// Unconditionally resets all recording state. Use when the recorder is stuck
    /// in a bad state (engine dead, config change loop, etc.) and normal stopRecording()
    /// can't recover. Does NOT return the recording — the audio is lost.
    func forceReset() {
        Self.logger.warning("Force-resetting audio recorder — cleaning up all state")
        _isCapturing.withLock { $0 = false }

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        durationTimer?.invalidate()
        durationTimer = nil

        noAudioWatchdog?.invalidate()
        noAudioWatchdog = nil

        // If the engine is still running, stop it cleanly (remove tap, then stop).
        // If it was stopped by the system (AVAudioEngineConfigurationChange), do NOT
        // access inputNode — the underlying HAL device may be in an inconsistent state.
        //
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
        isRecording = false
        recordingDuration = 0

        // Clean up temp file — audio is lost anyway
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
        }
    }

    private func checkNoAudioWatchdog() {
        guard isRecording else { return }
        let frames = _framesWritten.withLock { $0 }
        if frames < 800 {
            Self.logger.error("Watchdog: recording for 5s with only \(frames) frames — auto-stopping")
            let message = "No audio captured after 5 seconds. Check your microphone or try reconnecting your headphones."
            forceReset()
            onRecordingFailed?(message)
        } else {
            Self.logger.info("Watchdog: \(frames) frames captured — recording healthy")
            onRecordingStable?()
        }
    }

    // MARK: - Core Audio device enumeration

    /// Finds the built-in microphone device ID by scanning all audio devices
    /// for one with transport type kAudioDeviceTransportTypeBuiltIn and input channels.
    private static func findBuiltInMicDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices
        ) == noErr else { return nil }

        for device in devices {
            // Check transport type
            var transportType: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(device, &transportAddr, 0, nil, &size, &transportType) == noErr,
                  transportType == kAudioDeviceTransportTypeBuiltIn else { continue }

            // Check if it has input channels
            var inputAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufferListSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputAddr, 0, nil, &bufferListSize) == noErr,
                  bufferListSize > 0 else { continue }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }
            guard AudioObjectGetPropertyData(device, &inputAddr, 0, nil, &bufferListSize, bufferListPtr) == noErr else { continue }

            let channelCount = bufferListPtr.pointee.mBuffers.mNumberChannels
            if channelCount > 0 {
                logger.info("Found built-in mic: deviceID=\(device), channels=\(channelCount)")
                return device
            }
        }

        logger.warning("No built-in microphone found")
        return nil
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