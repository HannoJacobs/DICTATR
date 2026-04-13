import AppKit

final class DICTATRAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDiagnostics.info(
            .audioDevices,
            "audio device snapshot at launch route=\(AudioDeviceDiagnostics.currentRouteSnapshot()) devices=\(AudioDeviceDiagnostics.availableDevicesSnapshot())"
        )
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
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.info(
            .lifecycle,
            "applicationWillTerminate route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )
    }
}
