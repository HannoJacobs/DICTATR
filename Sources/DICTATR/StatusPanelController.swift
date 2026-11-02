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
    private var desiredHeight: CGFloat = 520
    private var anchorFrame: NSRect?
    private var anchorScreen: NSScreen?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
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

    @objc private func toggle(_ sender: Any?) {
        if panel?.isVisible == true { hide() } else { show(clickedLocation: NSEvent.mouseLocation) }
    }

    func show(clickedLocation: NSPoint? = nil) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        if panel == nil { buildPanel() }
        guard let panel else { return }

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        anchorFrame = buttonFrame
        anchorScreen = buttonWindow.screen
        // Status-item windows can report their old display after a menu-bar click
        // on a second screen. Only an actual status-item click may override it.
        if let clickedLocation, !buttonFrame.insetBy(dx: -4, dy: -4).contains(clickedLocation),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(clickedLocation) }) {
            anchorScreen = screen
            anchorFrame = NSRect(x: clickedLocation.x - button.bounds.width / 2,
                                 y: screen.frame.maxY - NSStatusBar.system.thickness,
                                 width: button.bounds.width, height: NSStatusBar.system.thickness)
        }
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
        AppDiagnostics.info(.lifecycle, "Status panel shown borderless=\(panel.styleMask.contains(.titled) ? "no" : "yes") opaque=\(panel.isOpaque) cornerRadius=\(panel.contentView?.layer?.cornerRadius ?? 0) frame=\(panel.frame)")
    }

    private func positionPanel() {
        guard let panel, let anchorFrame else { return }
        let visible = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchorFrame
        let size = NSSize(width: min(360, visible.width - 16), height: min(desiredHeight, visible.height - 16))
        let x = max(visible.minX + 8, min(anchorFrame.midX - size.width / 2, visible.maxX - size.width - 8))
        let y = max(visible.minY + 8, min(anchorFrame.minY, visible.maxY) - size.height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        AppDiagnostics.info(.lifecycle, "Status panel positioned anchor=\(anchorFrame) frame=\(panel.frame) desiredHeight=\(desiredHeight)")
    }

    private func resize(to height: CGFloat) {
        guard height > 0, abs(desiredHeight - height) > 1 else { return }
        desiredHeight = height
        // Geometry preferences arrive during SwiftUI layout; resize next turn.
        DispatchQueue.main.async { [weak self] in self?.positionPanel() }
    }

    private func hide() {
        panel?.orderOut(nil)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func buildPanel() {
        let root = StatusPanelView(appState: appState,
                                   onShowHistory: { [weak self] in self?.showHistory() },
                                   onHeightChange: { [weak self] in self?.resize(to: $0) })
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true

        let panel = DictationStatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
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
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        Group {
            if appState.shouldShowOnboarding {
                ScrollView { OnboardingView() }
                    .onAppear { onHeightChange(520) }
            } else {
                MenuBarView(onShowHistory: onShowHistory, onHeightChange: onHeightChange)
            }
        }
        .environment(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}
