import SwiftUI

@main
struct DICTATRApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("DICTATR", systemImage: appState.menuBarIcon) {
            if !appState.hasCompletedOnboarding {
                OnboardingView()
                    .environment(appState)
            } else if !appState.isModelLoaded {
                ModelDownloadView()
                    .environment(appState)
            } else {
                MenuBarView()
                    .environment(appState)
            }
        }
        .menuBarExtraStyle(.window)

        Window("History", id: "history") {
            HistoryListView()
                .environment(appState)
        }
        .defaultSize(width: 400, height: 500)
    }
}
