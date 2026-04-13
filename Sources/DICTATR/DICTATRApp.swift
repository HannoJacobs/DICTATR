import SwiftUI

@main
struct DICTATRApp: App {
    @NSApplicationDelegateAdaptor(DICTATRAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("DICTATR", systemImage: appState.menuBarIcon) {
            if appState.shouldShowOnboarding {
                OnboardingView()
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
