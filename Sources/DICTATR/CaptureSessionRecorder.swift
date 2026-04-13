import AVFoundation
import CoreMedia
import Foundation
import os

struct CaptureSessionStartResult {
    let selectedDeviceUID: String
    let selectedDeviceName: String
    let firstSampleFormat: AudioGraphFormatSnapshot
}

struct CaptureSessionFailureEvent {
    let reason: RecordingFailureReason
    let detail: String
}

final class CaptureSessionRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private struct StartupWaitState {
        var continuation: AsyncThrowingStream<CaptureSessionStartResult, Error>.Continuation?
        var timeoutTask: Task<Void, Never>?
        var completed = false
    }

    private let targetFormat: AVAudioFormat
    private let outputFile: AVAudioFile
    private let isCapturing: OSAllocatedUnfairLock<Bool>
    private let framesWritten: OSAllocatedUnfairLock<Int64>
    private let droppedFrames: OSAllocatedUnfairLock<Int64>
    private let captureStats: OSAllocatedUnfairLock<RealtimeCaptureStats>
    private let onFirstSample: @MainActor (AudioGraphFormatSnapshot) -> Void
    private let onEvent: @MainActor (String, String) -> Void
    private let onFailure: @MainActor (CaptureSessionFailureEvent) -> Void

    private let session = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.dictatr.capture-session.control")
    private let sampleQueue = DispatchQueue(label: "com.dictatr.capture-session.samples")
    private let startupWaitState = OSAllocatedUnfairLock(initialState: StartupWaitState())

    private var runtimeErrorObserver: NSObjectProtocol?
    private var sessionInterruptedObserver: NSObjectProtocol?
    private var sessionInterruptionEndedObserver: NSObjectProtocol?
    private var deviceDisconnectedObserver: NSObjectProtocol?

    private var selectedDeviceUID = "unknown"
    private var selectedDeviceName = "unknown"
    private var selectedDeviceInput: AVCaptureDeviceInput?
    private var converter: AVAudioConverter?
    private var sourceFormatSnapshot: AudioGraphFormatSnapshot?
    private var hasDeliveredFirstSample = false

    init(
        targetFormat: AVAudioFormat,
        outputFile: AVAudioFile,
        isCapturing: OSAllocatedUnfairLock<Bool>,
        framesWritten: OSAllocatedUnfairLock<Int64>,
        droppedFrames: OSAllocatedUnfairLock<Int64>,
        captureStats: OSAllocatedUnfairLock<RealtimeCaptureStats>,
        onFirstSample: @escaping @MainActor (AudioGraphFormatSnapshot) -> Void,
        onEvent: @escaping @MainActor (String, String) -> Void,
        onFailure: @escaping @MainActor (CaptureSessionFailureEvent) -> Void
    ) {
        self.targetFormat = targetFormat
        self.outputFile = outputFile
        self.isCapturing = isCapturing
        self.framesWritten = framesWritten
        self.droppedFrames = droppedFrames
        self.captureStats = captureStats
        self.onFirstSample = onFirstSample
        self.onEvent = onEvent
        self.onFailure = onFailure
        super.init()
    }

    var isRunning: Bool {
        session.isRunning
    }

    func start(expectedInputDeviceUID: String, startupTimeoutMs: Int) async throws -> CaptureSessionStartResult {
        let candidates = CaptureDeviceSelection.availableAudioCaptureCandidates()
        guard let selection = CaptureDeviceSelection.resolve(expectedInputUID: expectedInputDeviceUID, candidates: candidates),
              let device = CaptureDeviceSelection.availableAudioCaptureDevices().first(where: { $0.uniqueID == selection.uniqueID }) else {
            throw AudioRecorderError.captureDeviceSelectionFailed(
                "No AVCaptureDevice matched active default input uid \(expectedInputDeviceUID). availableCaptureDevices=\(CaptureDeviceSelection.availableSnapshot())"
            )
        }

        selectedDeviceUID = selection.uniqueID
        selectedDeviceName = selection.localizedName
        hasDeliveredFirstSample = false
        converter = nil
        sourceFormatSnapshot = nil
        captureOutput.audioSettings = nil
        if #available(macOS 26.0, *), captureOutput.isDeferredStartSupported {
            captureOutput.isDeferredStartEnabled = false
        }

        let input = try AVCaptureDeviceInput(device: device)
        selectedDeviceInput = input

        session.beginConfiguration()
        var shouldCommitConfigurationInDefer = true
        defer {
            if shouldCommitConfigurationInDefer {
                session.commitConfiguration()
            }
        }

        for existingInput in session.inputs {
            session.removeInput(existingInput)
        }
        for existingOutput in session.outputs {
            session.removeOutput(existingOutput)
        }

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

        captureOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        session.commitConfiguration()
        shouldCommitConfigurationInDefer = false

        installObservers(for: device)

        let startupStream = makeStartupStream(timeoutMs: startupTimeoutMs)

        sessionQueue.sync {
            self.session.startRunning()
        }

        if !session.isRunning {
            let error = AudioRecorderError.captureSessionConfigurationFailed("AVCaptureSession failed to start running")
            failStartupIfNeeded(error: error)
        }

        for try await result in startupStream {
            return result
        }

        throw AudioRecorderError.captureStartupTimedOut("Timed out waiting for first audio sample from AVCaptureSession")
    }

    func stop() {
        captureOutput.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.sync {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        removeObservers()
        selectedDeviceInput = nil
        failStartupIfNeeded(error: AudioRecorderError.captureSessionConfigurationFailed("Capture session stopped before first sample"))
    }

    func forceReset() {
        stop()
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

        if sourceFormatSnapshot != formatSnapshot {
            sourceFormatSnapshot = formatSnapshot
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            Task { @MainActor in
                self.onEvent(
                    "capture_session_source_format_observed",
                    "selectedDeviceUID=\(self.selectedDeviceUID) selectedDeviceName=\(self.selectedDeviceName) sourceFormat={\(formatSnapshot.description)} targetFormat={\(AudioGraphFormatSnapshot(self.targetFormat).description)}"
                )
            }
        }

        if firstSampleSeen {
            hasDeliveredFirstSample = true
            completeStartupIfNeeded(
                with: CaptureSessionStartResult(
                    selectedDeviceUID: selectedDeviceUID,
                    selectedDeviceName: selectedDeviceName,
                    firstSampleFormat: formatSnapshot
                )
            )
            Task { @MainActor in
                self.onEvent(
                    "capture_session_first_sample",
                    "selectedDeviceUID=\(self.selectedDeviceUID) selectedDeviceName=\(self.selectedDeviceName) sourceFormat={\(formatSnapshot.description)}"
                )
                self.onFirstSample(formatSnapshot)
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
            self.onEvent(event, "selectedDeviceUID=\(self.selectedDeviceUID) targetFormat={\(AudioGraphFormatSnapshot(self.targetFormat).description)}")
        }
    }

    private func installObservers(for device: AVCaptureDevice) {
        removeObservers()

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleRuntimeError(notification)
        }

        sessionInterruptedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterrupted(notification)
        }

        sessionInterruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterruptionEnded(notification)
        }

        deviceDisconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] notification in
            self?.handleDeviceDisconnected(notification)
        }
    }

    private func removeObservers() {
        for observer in [runtimeErrorObserver, sessionInterruptedObserver, sessionInterruptionEndedObserver, deviceDisconnectedObserver] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        runtimeErrorObserver = nil
        sessionInterruptedObserver = nil
        sessionInterruptionEndedObserver = nil
        deviceDisconnectedObserver = nil
    }

    private func makeStartupStream(timeoutMs: Int) -> AsyncThrowingStream<CaptureSessionStartResult, Error> {
        AsyncThrowingStream { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                self?.failStartupIfNeeded(
                    error: AudioRecorderError.captureStartupTimedOut(
                        "Timed out after \(timeoutMs)ms waiting for first audio sample from selected device \(self?.selectedDeviceUID ?? "unknown")"
                    )
                )
            }

            startupWaitState.withLock { state in
                state.continuation = continuation
                state.timeoutTask = timeoutTask
                state.completed = false
            }
        }
    }

    private func completeStartupIfNeeded(with result: CaptureSessionStartResult) {
        let (continuation, timeoutTask) = startupWaitState.withLock { state -> (AsyncThrowingStream<CaptureSessionStartResult, Error>.Continuation?, Task<Void, Never>?) in
            guard !state.completed else { return (nil, nil) }
            state.completed = true
            let continuation = state.continuation
            let timeoutTask = state.timeoutTask
            state.continuation = nil
            state.timeoutTask = nil
            return (continuation, timeoutTask)
        }

        timeoutTask?.cancel()
        continuation?.yield(result)
        continuation?.finish()
    }

    private func failStartupIfNeeded(error: Error) {
        let (continuation, timeoutTask) = startupWaitState.withLock { state -> (AsyncThrowingStream<CaptureSessionStartResult, Error>.Continuation?, Task<Void, Never>?) in
            guard !state.completed else { return (nil, nil) }
            state.completed = true
            let continuation = state.continuation
            let timeoutTask = state.timeoutTask
            state.continuation = nil
            state.timeoutTask = nil
            return (continuation, timeoutTask)
        }

        timeoutTask?.cancel()
        continuation?.finish(throwing: error)
    }

    private func handleRuntimeError(_ notification: Notification) {
        let detail = describe(notification: notification)
        let error = AudioRecorderError.captureSessionRuntimeError(detail)
        if !hasDeliveredFirstSample {
            failStartupIfNeeded(error: error)
            return
        }

        Task { @MainActor in
            self.onEvent("capture_session_runtime_error", detail)
            self.onFailure(CaptureSessionFailureEvent(reason: .captureSessionRuntimeError, detail: detail))
        }
    }

    private func handleSessionInterrupted(_ notification: Notification) {
        let detail = describe(notification: notification)
        let error = AudioRecorderError.captureSessionRuntimeError(detail)
        if !hasDeliveredFirstSample {
            failStartupIfNeeded(error: error)
            return
        }

        Task { @MainActor in
            self.onEvent("capture_session_interrupted", detail)
            self.onFailure(CaptureSessionFailureEvent(reason: .captureSessionRuntimeError, detail: detail))
        }
    }

    private func handleSessionInterruptionEnded(_ notification: Notification) {
        let detail = describe(notification: notification)
        Task { @MainActor in
            self.onEvent("capture_session_interruption_ended", detail)
        }
    }

    private func handleDeviceDisconnected(_ notification: Notification) {
        let detail = describe(notification: notification)
        let error = AudioRecorderError.captureSessionRuntimeError(detail)
        if !hasDeliveredFirstSample {
            failStartupIfNeeded(error: error)
            return
        }

        Task { @MainActor in
            self.onEvent("capture_session_device_disconnected", detail)
            self.onFailure(CaptureSessionFailureEvent(reason: .captureDeviceDisconnected, detail: detail))
        }
    }

    private func describe(notification: Notification) -> String {
        let userInfo = (notification.userInfo ?? [:])
            .map { key, value in
                "\(key)=\(AppDiagnostics.compactText(String(describing: value), limit: 200))"
            }
            .sorted()
            .joined(separator: ",")
        return "selectedDeviceUID=\(selectedDeviceUID) selectedDeviceName=\(selectedDeviceName) name=\(notification.name.rawValue) userInfo={\(userInfo)}"
    }
}
