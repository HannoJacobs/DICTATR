import AppKit
import Observation
import SwiftUI

/// Uses the same transparent, rounded native panel shell as SOURCR and LIMTR.
@MainActor
final class StatusPanelController: NSObject {
    private let appState: AppState
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var historyWindow: NSWindow?
    private var outsideClickMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "DICTATR"
        item.button?.setAccessibilityLabel("DICTATR")
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        withObservationTracking {
            statusItem?.button?.image = NSImage(systemSymbolName: appState.menuBarIcon, accessibilityDescription: "DICTATR")
            statusItem?.button?.image?.isTemplate = true
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateStatusIcon() }
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        if panel == nil { buildPanel() }
        guard let panel else { return }

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? buttonWindow.screen
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? buttonFrame
        let size = NSSize(width: min(380, visible.width - 16), height: min(560, visible.height - 16))
        let anchorX = screen == buttonWindow.screen ? buttonFrame.maxX : NSEvent.mouseLocation.x + button.bounds.width / 2
        let x = max(visible.minX + 8, min(anchorX - size.width, visible.maxX - size.width - 8))
        panel.setFrame(NSRect(x: x, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
        AppDiagnostics.info(.lifecycle, "Status panel shown borderless=\(panel.styleMask.contains(.titled) ? "no" : "yes") opaque=\(panel.isOpaque) cornerRadius=\(panel.contentView?.layer?.cornerRadius ?? 0) frame=\(panel.frame)")
    }

    private func hide() {
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func buildPanel() {
        let root = StatusPanelView(appState: appState, onShowHistory: { [weak self] in self?.showHistory() })
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true

        let panel = DictationStatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "DICTATR"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.hide() }
        self.panel = panel
    }

    private func showHistory() {
        hide()
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "History"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: HistoryListView().environment(appState))
            window.center()
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }
}

private final class DictationStatusPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct StatusPanelView: View {
    let appState: AppState
    let onShowHistory: () -> Void

    var body: some View {
        Group {
            if appState.shouldShowOnboarding {
                ScrollView { OnboardingView() }
            } else {
                MenuBarView(onShowHistory: onShowHistory)
            }
        }
        .environment(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}
