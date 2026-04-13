import AppKit
import AVFoundation
import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var accessibilityPollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            // Header
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
        .onDisappear {
            accessibilityPollTask?.cancel()
            accessibilityPollTask = nil
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
                .foregroundStyle(granted ? .green : Color.accentColor)
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
        appState.refreshPermissionStates(source: "onboardingAppear")
        microphoneGranted = MicrophonePermissionManager.authorizationState().isAuthorized

        // Check accessibility
        accessibilityGranted = PasteManager.checkAccessibilityPermission()
    }

    private func requestMicrophoneAccess() {
        Task { @MainActor in
            await appState.handleMicrophonePermissionAction(source: "onboarding")
            checkPermissions()
        }
    }

    private func requestAccessibilityAccess() {
        PasteManager.requestAccessibilityPermission()
        // Cancel any existing poll
        accessibilityPollTask?.cancel()
        // Use a structured Task for polling instead of Timer.
        // This automatically cancels when the view disappears (via onDisappear),
        // ensures @State is mutated on the MainActor, and has a timeout.
        accessibilityPollTask = Task { @MainActor in
            for _ in 0..<120 { // Poll for up to 2 minutes
                if Task.isCancelled { break }
                if PasteManager.checkAccessibilityPermission() {
                    accessibilityGranted = true
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
