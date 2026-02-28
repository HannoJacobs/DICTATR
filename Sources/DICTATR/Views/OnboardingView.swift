import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 24) {
            // Header
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.accent)

            Text("Welcome to DICTATR")
                .font(.title)
                .bold()

            Text("A few permissions are needed to get started.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            // Permission steps
            VStack(alignment: .leading, spacing: 16) {
                permissionRow(
                    icon: "mic",
                    title: "Microphone Access",
                    description: "Required to record your voice for dictation.",
                    granted: microphoneGranted,
                    action: requestMicrophoneAccess
                )

                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required to paste text into the active app.",
                    granted: accessibilityGranted,
                    action: requestAccessibilityAccess
                )
            }
            .padding()

            Spacer()

            // Continue button
            Button {
                appState.hasCompletedOnboarding = true
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!microphoneGranted)
        }
        .padding(32)
        .frame(width: 420, height: 480)
        .onAppear {
            checkPermissions()
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? .green : .accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func checkPermissions() {
        // Check microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        default:
            microphoneGranted = false
        }

        // Check accessibility
        accessibilityGranted = PasteManager.checkAccessibilityPermission()
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                microphoneGranted = granted
            }
        }
    }

    private func requestAccessibilityAccess() {
        PasteManager.requestAccessibilityPermission()
        // Poll for accessibility grant since there's no callback
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if PasteManager.checkAccessibilityPermission() {
                accessibilityGranted = true
                timer.invalidate()
            }
        }
    }
}
