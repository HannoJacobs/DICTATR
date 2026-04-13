import AVFoundation
import CoreMedia
import Foundation
import os

final class CaptureSessionRecorder {
    private let targetFormat: AVAudioFormat
    private let outputFile: AVAudioFile
    private let isCapturing: OSAllocatedUnfairLock<Bool>
    private let framesWritten: OSAllocatedUnfairLock<Int64>
    private let droppedFrames: OSAllocatedUnfairLock<Int64>
    private let captureStats: OSAllocatedUnfairLock<RealtimeCaptureStats>
    private let onFirstSample: @MainActor (AudioGraphFormatSnapshot) -> Void
    private let onEvent: @MainActor (String, String) -> Void

    private let session = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.dictatr.capture-session.control")
    private let sampleQueue = DispatchQueue(label: "com.dictatr.capture-session.samples")
    private let sampleSink: CaptureSessionSampleSink

    init(
        targetFormat: AVAudioFormat,
        outputFile: AVAudioFile,
        isCapturing: OSAllocatedUnfairLock<Bool>,
        framesWritten: OSAllocatedUnfairLock<Int64>,
        droppedFrames: OSAllocatedUnfairLock<Int64>,
        captureStats: OSAllocatedUnfairLock<RealtimeCaptureStats>,
        onFirstSample: @escaping @MainActor (AudioGraphFormatSnapshot) -> Void,
        onEvent: @escaping @MainActor (String, String) -> Void
    ) {
        self.targetFormat = targetFormat
        self.outputFile = outputFile
        self.isCapturing = isCapturing
        self.framesWritten = framesWritten
        self.droppedFrames = droppedFrames
        self.captureStats = captureStats
        self.onFirstSample = onFirstSample
        self.onEvent = onEvent
        self.sampleSink = CaptureSessionSampleSink(
            targetFormat: targetFormat,
            outputFile: outputFile,
            isCapturing: isCapturing,
            framesWritten: framesWritten,
            droppedFrames: droppedFrames,
            captureStats: captureStats,
            onFirstSample: onFirstSample,
            onEvent: onEvent
        )
    }

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioRecorderError.captureDeviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            throw AudioRecorderError.captureSessionConfigurationFailed("Failed to add audio input to AVCaptureSession")
        }

        if session.canAddOutput(captureOutput) {
            session.addOutput(captureOutput)
        } else {
            throw AudioRecorderError.captureSessionConfigurationFailed("Failed to add audio output to AVCaptureSession")
        }

        captureOutput.setSampleBufferDelegate(sampleSink, queue: sampleQueue)

        sessionQueue.sync {
            self.session.startRunning()
        }

        if !session.isRunning {
            throw AudioRecorderError.captureSessionConfigurationFailed("AVCaptureSession failed to start running")
        }
    }

    func stop() {
        captureOutput.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.sync {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func forceReset() {
        stop()
    }
}

private final class CaptureSessionSampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let targetFormat: AVAudioFormat
    private let outputFile: AVAudioFile
    private let isCapturing: OSAllocatedUnfairLock<Bool>
    private let framesWritten: OSAllocatedUnfairLock<Int64>
    private let droppedFrames: OSAllocatedUnfairLock<Int64>
    private let captureStats: OSAllocatedUnfairLock<RealtimeCaptureStats>
    private let onFirstSample: @MainActor (AudioGraphFormatSnapshot) -> Void
    private let onEvent: @MainActor (String, String) -> Void

    private var converter: AVAudioConverter?
    private var sourceFormatSnapshot: AudioGraphFormatSnapshot?

    init(
        targetFormat: AVAudioFormat,
        outputFile: AVAudioFile,
        isCapturing: OSAllocatedUnfairLock<Bool>,
        framesWritten: OSAllocatedUnfairLock<Int64>,
        droppedFrames: OSAllocatedUnfairLock<Int64>,
        captureStats: OSAllocatedUnfairLock<RealtimeCaptureStats>,
        onFirstSample: @escaping @MainActor (AudioGraphFormatSnapshot) -> Void,
        onEvent: @escaping @MainActor (String, String) -> Void
    ) {
        self.targetFormat = targetFormat
        self.outputFile = outputFile
        self.isCapturing = isCapturing
        self.framesWritten = framesWritten
        self.droppedFrames = droppedFrames
        self.captureStats = captureStats
        self.onFirstSample = onFirstSample
        self.onEvent = onEvent
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        _ = output
        _ = connection
        guard isCapturing.withLock({ $0 }) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let firstSampleSeen = captureStats.withLock { stats -> Bool in
            stats.tapCallbackCount += 1
            stats.buffersReceived += 1
            if let lastTapUptime = stats.lastTapUptime {
                stats.callbackIntervalTotalMs += (now - lastTapUptime) * 1000
                stats.callbackIntervalCount += 1
            }
            let isFirst = stats.firstTapUptime == nil
            if isFirst {
                stats.firstTapUptime = now
            }
            stats.lastTapUptime = now
            return isFirst
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            registerDroppedBuffer(event: "capture_session_invalid_format_description")
            return
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let formatSnapshot = AudioGraphFormatSnapshot(sourceFormat)
        if firstSampleSeen {
            Task { @MainActor in
                self.onFirstSample(formatSnapshot)
            }
        }

        if sourceFormatSnapshot != formatSnapshot {
            sourceFormatSnapshot = formatSnapshot
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            Task { @MainActor in
                self.onEvent(
                    "capture_session_source_format_observed",
                    "sourceFormat={\(formatSnapshot.description)} targetFormat={\(AudioGraphFormatSnapshot(self.targetFormat).description)}"
                )
            }
        }

        guard let converter else {
            registerDroppedBuffer(event: "capture_session_converter_missing")
            return
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            registerDroppedBuffer(event: "capture_session_input_buffer_unavailable")
            return
        }
        inputBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            registerDroppedBuffer(event: "capture_session_copy_failed status=\(copyStatus)")
            return
        }

        captureStats.withLock { stats in
            stats.framesReceivedRaw += Int64(frameCount)
            stats.largestInputBufferFrames = max(stats.largestInputBufferFrames, Int(frameCount))
            stats.smallestInputBufferFrames = min(stats.smallestInputBufferFrames, Int(frameCount))
        }

        let convertedFrameCount = AVAudioFrameCount(
            Double(frameCount) * targetFormat.sampleRate / sourceFormat.sampleRate
        )
        guard convertedFrameCount > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedFrameCount) else {
            registerDroppedBuffer(event: "capture_session_output_buffer_unavailable")
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
            return inputBuffer
        }

        if status == .haveData, error == nil {
            do {
                try outputFile.write(from: convertedBuffer)
                framesWritten.withLock { $0 += Int64(convertedBuffer.frameLength) }
                captureStats.withLock { stats in
                    stats.buffersConverted += 1
                    stats.framesConverted += Int64(convertedBuffer.frameLength)
                    stats.lastFrameWriteUptime = now
                    if convertedBuffer.frameLength > 0, stats.firstNonZeroWriteUptime == nil {
                        stats.firstNonZeroWriteUptime = now
                    }
                }
            } catch {
                registerDroppedBuffer(event: "capture_session_file_write_failed error=\(error.localizedDescription)")
            }
        } else {
            registerDroppedBuffer(event: "capture_session_conversion_failed status=\(status.rawValue) error=\(error?.localizedDescription ?? "none")")
        }
    }

    private func registerDroppedBuffer(event: String) {
        droppedFrames.withLock { $0 += 1 }
        captureStats.withLock { $0.buffersDropped += 1 }
        Task { @MainActor in
            self.onEvent(event, "targetFormat={\(AudioGraphFormatSnapshot(self.targetFormat).description)}")
        }
    }
}
