import AVFoundation
import Foundation

enum CaptureDeviceSelection {
    struct Candidate: Equatable {
        let uniqueID: String
        let localizedName: String
    }

    static func resolve(expectedInputUID: String, candidates: [Candidate]) -> Candidate? {
        candidates.first { $0.uniqueID == expectedInputUID }
    }

    static func availableAudioCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func availableAudioCaptureCandidates() -> [Candidate] {
        availableAudioCaptureDevices().map { device in
            Candidate(uniqueID: device.uniqueID, localizedName: device.localizedName)
        }
    }

    static func availableSnapshot() -> String {
        let candidates = availableAudioCaptureCandidates()
        guard !candidates.isEmpty else { return "none" }
        return candidates.map { "{uid=\($0.uniqueID) name=\($0.localizedName)}" }.joined(separator: " ")
    }
}
