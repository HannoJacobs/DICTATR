import KeyboardShortcuts

final class HotkeyManager {
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        AppDiagnostics.info(.hotkey, "HotkeyManager initializing for toggleDictation")

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            AppDiagnostics.info(
                .hotkey,
                "toggleDictation keyUp received \(AppDiagnostics.threadSummary()) \(AppDiagnostics.frontmostAppSummary()) route=\(AudioDeviceDiagnostics.currentRouteSnapshot())"
            )
            self?.onToggle()
        }

        AppDiagnostics.info(.hotkey, "HotkeyManager registered keyUp handler for toggleDictation")
    }

    deinit {
        AppDiagnostics.info(.hotkey, "HotkeyManager deinit resetting toggleDictation shortcut")
        KeyboardShortcuts.reset(.toggleDictation)
    }
}
