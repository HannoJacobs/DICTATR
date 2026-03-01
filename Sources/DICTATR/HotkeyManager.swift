import KeyboardShortcuts

final class HotkeyManager {
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            self?.onToggle()
        }
    }

    deinit {
        KeyboardShortcuts.reset(.toggleDictation)
    }
}
