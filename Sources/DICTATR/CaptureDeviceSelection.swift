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

    static func preference(from candidate: Candidate) -> InputDevicePreference {
        InputDevicePreference(uid: candidate.uniqueID, name: candidate.localizedName)
    }

    static func availableAudioCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func availableAudioCaptureCandidates() -> [Candidate] {
        availableAudioCaptureDevices().map {
            Candidate(uniqueID: $0.uniqueID, localizedName: $0.localizedName)
        }
    }

    static func availableSnapshot() -> String {
        let candidates = availableAudioCaptureCandidates()
        guard !candidates.isEmpty else { return "none" }
        return candidates
            .map { "{uid=\($0.uniqueID) name=\($0.localizedName)}" }
            .joined(separator: " ")
    }
}
