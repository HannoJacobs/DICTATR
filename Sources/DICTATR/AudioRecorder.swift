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

    // Thread-safe flags readable from the real-time audio thread.
    // @Observable's isRecording is not safe to read from the audio thread.
    // OSAllocatedUnfairLock provides proper atomicity for cross-thread access.
    private let _isCapturing = OSAllocatedUnfairLock(initialState: false)
    private let _framesWritten = OSAllocatedUnfairLock(initialState: Int64(0))
    private let _droppedFrames = OSAllocatedUnfairLock(initialState: Int64(0))

    func startRecording() throws -> URL {
        // Guard against double-start — clean up any existing session first
        if isRecording {
            if let result = stopRecording() {
                try? FileManager.default.removeItem(at: result.url)
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "dictatr_\(Int(Date().timeIntervalSince1970)).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Self.logger.error("Invalid input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
            throw AudioRecorderError.invalidInputFormat
        }
        Self.logger.info("Recording with input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Target format: 16kHz mono Float32 (what Whisper expects)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
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

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self, file] buffer, _ in
            // Read atomic flag instead of @Observable isRecording (audio thread safety).
            // Capture `file` directly to avoid accessing self.outputFile from the audio thread (data race).
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
                // Log every 100th drop to avoid spamming the audio thread
                if dropped % 100 == 1 {
                    Self.logger.warning("Audio frame dropped (\(dropped) total): frameCount=0, inputSR=\(inputFormat.sampleRate)")
                }
                return
            }

            var error: NSError?
            // Track whether input data has already been supplied to avoid returning
            // the same buffer multiple times (the converter may call the block repeatedly)
            var inputConsumed = false
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
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

        do {
            try engine.start()
        } catch {
            // Clean up the tap, file, and state since engine failed to start
            self._isCapturing.withLock { $0 = false }
            inputNode.removeTap(onBus: 0)
            self.outputFile = nil
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        self.audioEngine = engine
        self.outputURL = fileURL
        self.isRecording = true
        self.recordingDuration = 0
        self.recordingStartTime = ProcessInfo.processInfo.systemUptime

        // Observe audio configuration changes (device connect/disconnect, Bluetooth profile switch)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange(targetFormat: targetFormat)
            }
        }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = ProcessInfo.processInfo.systemUptime - start
            }
        }

        return fileURL
    }

    private func handleConfigurationChange(targetFormat: AVAudioFormat) {
        guard isRecording, let engine = audioEngine, let file = outputFile else { return }

        Self.logger.info("Audio configuration changed during recording — reinstalling tap")

        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)

        let newInputFormat = inputNode.outputFormat(forBus: 0)

        guard newInputFormat.sampleRate > 0, newInputFormat.channelCount > 0 else {
            Self.logger.warning("New input format invalid after config change: sampleRate=\(newInputFormat.sampleRate), channels=\(newInputFormat.channelCount). Continuing with partial recording.")
            return
        }

        guard let newConverter = AVAudioConverter(from: newInputFormat, to: targetFormat) else {
            Self.logger.error("Failed to create converter for new input format after config change")
            return
        }

        Self.logger.info("Reinstalling tap with new format: \(newInputFormat.sampleRate)Hz, \(newInputFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: newInputFormat) { [weak self, file] buffer, _ in
            guard let self, self._isCapturing.withLock({ $0 }) else { return }
            let outFile = file

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / newInputFormat.sampleRate
            )
            guard frameCount > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else {
                self._droppedFrames.withLock { $0 += 1 }
                return
            }

            var error: NSError?
            var inputConsumed = false
            let status = newConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
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
                Self.logger.warning("Audio conversion failed after config change: \(error.localizedDescription)")
            }
        }

        do {
            try engine.start()
        } catch {
            Self.logger.error("Failed to restart engine after config change: \(error.localizedDescription)")
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

        // Compute final duration from monotonic clock for accuracy (timer is up to 100ms stale)
        let duration: TimeInterval
        if let start = recordingStartTime {
            duration = ProcessInfo.processInfo.systemUptime - start
        } else {
            duration = recordingDuration
        }

        let frames = _framesWritten.withLock { $0 }
        let dropped = _droppedFrames.withLock { $0 }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        outputFile = nil
        recordingStartTime = nil

        Self.logger.info("Recording stopped: \(frames) frames written, \(dropped) frames dropped, \(String(format: "%.1f", duration))s duration")

        return (url, duration, frames)
    }
}

enum AudioRecorderError: LocalizedError {
    case formatCreationFailed
    case converterCreationFailed
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create target audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .invalidInputFormat:
            return "No microphone input detected. Check your audio device."
        }
    }
}
