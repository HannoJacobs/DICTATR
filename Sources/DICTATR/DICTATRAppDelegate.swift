import AppKit

@MainActor
final class DICTATRAppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState?
    private var panelController: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        appState = state
        let controller = StatusPanelController(appState: state)
        panelController = controller
        controller.install()
        AppDiagnostics.info(
            .audioDevices,
            "audio device snapshot at launch route=\(AudioDeviceDiagnostics.currentRouteSnapshot()) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
        if state.shouldShowOnboarding {
            controller.show()
        }
        AppDiagnostics.info(
            .lifecycle,
            "applicationDidFinishLaunching \(AppDiagnostics.runtimeSummary) accessibilityTrusted=\(PasteManager.accessibilityStatusSummary()) microphoneStatus=\(MicrophonePermissionManager.authorizationStatusSummary()) route=\(AudioDeviceDiagnostics.currentRouteSnapshot()) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDiagnostics.info(
            .lifecycle,
            "applicationDidBecomeActive route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppDiagnostics.info(
            .lifecycle,
            "applicationShouldHandleReopen hasVisibleWindows=\(flag) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
        panelController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.info(
            .lifecycle,
            "applicationWillTerminate route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
    }
}
