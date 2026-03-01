import AppKit
import SwiftUI

@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?
    private var state = IndicatorState()
    private var autoDismissTask: Task<Void, Never>?

    // Fixed size large enough for all phases. The panel background is clear,
    // so extra space is invisible — only the capsule background shows.
    // This avoids the infinite Auto Layout constraint loop that happens when
    // resizing the panel in response to @Observable state changes.
    private static let panelSize = NSSize(width: 260, height: 50)

    func show(audioRecorder: AudioRecorder) {
        autoDismissTask?.cancel()
        state.phase = .recording
        state.audioRecorder = audioRecorder

        if panel != nil { return }

        let view = RecordingIndicatorView(state: state)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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
            let x = screenFrame.maxX - Self.panelSize.width - 12
            let y = screenFrame.maxY - Self.panelSize.height - 8
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        p.orderFrontRegardless()
        self.panel = p
    }

    func showProcessing() {
        autoDismissTask?.cancel()
        state.phase = .processing
    }

    func showDone() {
        autoDismissTask?.cancel()
        state.phase = .done
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        dismiss()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        state.phase = .idle
        state.audioRecorder = nil
    }
}

// MARK: - State

enum IndicatorPhase {
    case idle, recording, processing, done
}

@Observable
@MainActor
final class IndicatorState {
    var phase: IndicatorPhase = .idle
    var audioRecorder: AudioRecorder?
}

// MARK: - SwiftUI View

private struct RecordingIndicatorView: View {
    let state: IndicatorState
    @State private var isPulsing = false

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                switch state.phase {
                case .idle:
                    EmptyView()

                case .recording:
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .scaleEffect(isPulsing ? 1.3 : 0.8)
                        .opacity(isPulsing ? 1.0 : 0.6)

                    Text(formatDuration(state.audioRecorder?.recordingDuration ?? 0))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)

                case .processing:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)

                    Text("Processing...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)

                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)

                    Text("Copied to clipboard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.black.opacity(0.75))
            )
        }
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
