import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?

    func show(audioRecorder: AudioRecorder) {
        if panel != nil { return }

        let view = RecordingIndicatorView(audioRecorder: audioRecorder)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 130, height: 40)

        let p = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = false
        p.ignoresMouseEvents = true
        p.contentView = hostingView

        // Position: top-right corner, below menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - hostingView.frame.width - 12
            let y = screenFrame.maxY - hostingView.frame.height - 8
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()
        self.panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - SwiftUI View

private struct RecordingIndicatorView: View {
    let audioRecorder: AudioRecorder
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing ? 1.3 : 0.8)
                .opacity(isPulsing ? 1.0 : 0.6)

            Text(formatDuration(audioRecorder.recordingDuration))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.black.opacity(0.75))
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
