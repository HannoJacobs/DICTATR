import AVFoundation
import Foundation
import os

@Observable
@MainActor
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var recordingDuration: TimeInterval = 0

    private var audioEngine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var recordingStartTime: TimeInterval?
    private var durationTimer: Timer?

    // Thread-safe flag readable from the real-time audio thread.
    // @Observable's isRecording is not safe to read from the audio thread.
    // OSAllocatedUnfairLock provides proper atomicity for cross-thread access.
    private let _isCapturing = OSAllocatedUnfairLock(initialState: false)

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
            else { return }

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
                try? outFile.write(from: convertedBuffer)
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

        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.recordingDuration = ProcessInfo.processInfo.systemUptime - start
            }
        }

        return fileURL
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        guard isRecording, let url = outputURL else { return nil }

        // Signal the tap callback to stop writing BEFORE tearing down the engine.
        // This prevents the tap from writing with invalid buffers after engine stop.
        _isCapturing.withLock { $0 = false }
        isRecording = false

        durationTimer?.invalidate()
        durationTimer = nil

        // Compute final duration from monotonic clock for accuracy (timer is up to 100ms stale)
        let duration: TimeInterval
        if let start = recordingStartTime {
            duration = ProcessInfo.processInfo.systemUptime - start
        } else {
            duration = recordingDuration
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        outputFile = nil
        recordingStartTime = nil

        return (url, duration)
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
