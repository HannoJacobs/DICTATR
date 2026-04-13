import AppKit
import ApplicationServices
import CoreGraphics

enum PasteResult {
    case pasted
    case copiedOnly
    case noAccessibility
}

struct PasteManager {
    @MainActor
    static func paste(text: String, autoPaste: Bool = true) async -> PasteResult {
        AppDiagnostics.info(
            .pasteboard,
            "paste requested chars=\(text.count) autoPaste=\(AppDiagnostics.boolLabel(autoPaste)) text=\(AppDiagnostics.quoted(text, limit: 1200)) accessibilityTrusted=\(accessibilityStatusSummary()) \(AppDiagnostics.frontmostAppSummary()) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
        )

        // Write to system clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrotePasteboard = pasteboard.setString(text, forType: .string)
        AppDiagnostics.info(
            .pasteboard,
            "pasteboard write completed success=\(AppDiagnostics.boolLabel(wrotePasteboard)) changeCount=\(pasteboard.changeCount) chars=\(text.count)"
        )

        guard autoPaste else {
            AppDiagnostics.info(.pasteboard, "paste returning copiedOnly because autoPaste is disabled")
            return .copiedOnly
        }
        guard checkAccessibilityPermission() else {
            AppDiagnostics.warning(.pasteboard, "paste returning noAccessibility because AX permission is not granted")
            return .noAccessibility
        }

        // Small delay to ensure clipboard is ready
        try? await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V keystroke
        simulatePaste()
        AppDiagnostics.info(.pasteboard, "paste simulated Cmd+V successfully")
        return .pasted
    }

    static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        AppDiagnostics.info(.pasteboard, "requestAccessibilityPermission invoked")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func accessibilityStatusSummary() -> String {
        checkAccessibilityPermission() ? "yes" : "no"
    }

    static func accessibilitySettingsURL() -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAccessibilitySettings() {
        guard let url = accessibilitySettingsURL() else { return }
        AppDiagnostics.info(.pasteboard, "openAccessibilitySettings url=\(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    private static func simulatePaste() {
        let vKeyCode: CGKeyCode = 9 // 'v' key

        let source = CGEventSource(stateID: .hidSystemState)
        if source == nil {
            AppDiagnostics.error(.pasteboard, "simulatePaste failed to create CGEventSource")
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            AppDiagnostics.error(.pasteboard, "simulatePaste failed to create keyboard events")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        AppDiagnostics.info(.pasteboard, "simulatePaste posted command+v events")
    }
}
