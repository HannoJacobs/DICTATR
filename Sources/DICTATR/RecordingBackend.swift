import AVFoundation
import Foundation

enum RecorderBackendKind: String, CaseIterable, Sendable {
    case audioEngine
    case captureSession
}

enum RecorderBackendSelection {
    private static let defaultsKey = "internalRecorderBackend"
    private static let environmentKey = "DICTATR_RECORDER_BACKEND"

    static func current() -> RecorderBackendKind {
        if let rawValue = ProcessInfo.processInfo.environment[environmentKey],
           let kind = RecorderBackendKind(rawValue: rawValue) {
            return kind
        }

        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
           let kind = RecorderBackendKind(rawValue: rawValue) {
            return kind
        }

        return .audioEngine
    }
}

struct AudioGraphFormatSnapshot: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let commonFormatRawValue: Int

    init(sampleRate: Double, channelCount: UInt32, commonFormatRawValue: Int = 0) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.commonFormatRawValue = commonFormatRawValue
    }

    init(_ format: AVAudioFormat) {
        self.init(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            commonFormatRawValue: Int(format.commonFormat.rawValue)
        )
    }

    static let invalid = AudioGraphFormatSnapshot(sampleRate: 0, channelCount: 0)

    var isValid: Bool {
        sampleRate > 0 && channelCount > 0
    }

    var description: String {
        let sampleRateDescription = String(format: "%.1f", sampleRate)
        return "\(sampleRateDescription)Hz/\(channelCount)ch/commonFormat=\(commonFormatRawValue)"
    }
}

enum AudioGraphReadinessReason: String, Sendable {
    case readyLiveGraph = "ready_live_graph"
    case invalidLiveFormat = "invalid_live_format"
    case graphMismatch = "graph_mismatch"
    case bluetoothGraphMismatch = "bluetooth_graph_mismatch"
}

struct AudioGraphReadinessDecision: Equatable, Sendable {
    let shouldInstallTap: Bool
    let reason: AudioGraphReadinessReason
    let detail: String
}

enum RecordingStartupGate {
    static func tapInstallDecision(
        routeInvolvesBluetooth: Bool,
        inputFormat: AudioGraphFormatSnapshot,
        outputFormat: AudioGraphFormatSnapshot
    ) -> AudioGraphReadinessDecision {
        guard inputFormat.isValid, outputFormat.isValid else {
            return AudioGraphReadinessDecision(
                shouldInstallTap: false,
                reason: .invalidLiveFormat,
                detail: "inputFormat={\(inputFormat.description)} outputFormat={\(outputFormat.description)}"
            )
        }

        let formatsMatch = inputFormat.sampleRate == outputFormat.sampleRate &&
            inputFormat.channelCount == outputFormat.channelCount

        guard formatsMatch else {
            return AudioGraphReadinessDecision(
                shouldInstallTap: false,
                reason: routeInvolvesBluetooth ? .bluetoothGraphMismatch : .graphMismatch,
                detail: "inputFormat={\(inputFormat.description)} outputFormat={\(outputFormat.description)}"
            )
        }

        return AudioGraphReadinessDecision(
            shouldInstallTap: true,
            reason: .readyLiveGraph,
            detail: "inputFormat={\(inputFormat.description)} outputFormat={\(outputFormat.description)}"
        )
    }

    static func retrySuccessGateSatisfied(
        lastObservedRouteChangeMsAgo: Int,
        graphReady: Bool,
        firstTapSeen: Bool
    ) -> Bool {
        _ = lastObservedRouteChangeMsAgo
        return graphReady || firstTapSeen
    }

    static func startupDeadlineShouldFail(
        lastObservedRouteChangeMsAgo: Int,
        graphReady: Bool,
        firstTapSeen: Bool
    ) -> Bool {
        !retrySuccessGateSatisfied(
            lastObservedRouteChangeMsAgo: lastObservedRouteChangeMsAgo,
            graphReady: graphReady,
            firstTapSeen: firstTapSeen
        )
    }
}
