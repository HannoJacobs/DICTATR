import AVFoundation
import AppKit

enum MicrophoneAuthorizationState: String {
    case authorized
    case notDetermined
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .restricted
        }
    }

    var isAuthorized: Bool {
        self == .authorized
    }

    var userVisibleLabel: String {
        switch self {
        case .authorized:
            return "Granted"
        case .notDetermined:
            return "Not Requested"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        }
    }
}

enum MicrophonePermissionManager {
    static func authorizationState() -> MicrophoneAuthorizationState {
        MicrophoneAuthorizationState(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    static func authorizationStatusSummary() -> String {
        authorizationState().rawValue
    }

    static func requestAccess(source: String = "unspecified") async -> Bool {
        let preStatus = authorizationState()
        AppDiagnostics.info(.appState, "microphone permission request start source=\(source) current=\(preStatus.rawValue)")
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                let effectiveStatus = authorizationState()
                AppDiagnostics.info(
                    .appState,
                    "microphone permission request result source=\(source) granted=\(AppDiagnostics.boolLabel(granted)) effectiveStatus=\(effectiveStatus.rawValue)"
                )
                continuation.resume(returning: granted)
            }
        }
    }

    static func settingsURL() -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSettings(source: String = "unspecified") {
        guard let url = settingsURL() else { return }
        AppDiagnostics.warning(
            .appState,
            "microphone permission open settings source=\(source) status=\(authorizationState().rawValue) url=\(url.absoluteString)"
        )
        NSWorkspace.shared.open(url)
    }
}
