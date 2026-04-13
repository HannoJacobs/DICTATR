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
        // Write to system clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard autoPaste else { return .copiedOnly }
        guard checkAccessibilityPermission() else { return .noAccessibility }

        // Small delay to ensure clipboard is ready
        try? await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V keystroke
        simulatePaste()
        return .pasted
    }

    static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
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
        NSWorkspace.shared.open(url)
    }

    private static func simulatePaste() {
        let vKeyCode: CGKeyCode = 9 // 'v' key

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
