# Settings Button Crash Bug

## Symptom
Clicking "Settings..." in the MenuBarExtra popup immediately kills/crashes the app. This happens consistently in the DMG-distributed version (manually bundled .app). The dictation, recording, and other buttons work fine.

## Root Cause (suspected but not confirmed)
When Settings is clicked, the view transitions to `GeneralSettingsView`. Something in that view's render cycle crashes the app. The leading suspect is `LaunchAtLogin.Toggle` which calls `SMAppService` — this may crash in an unsigned/manually-bundled app. However, removing it did NOT fix the issue, so there may be another crash source in `GeneralSettingsView` or the view transition itself.

## What Has Been Tried

### 1. Separate Window scene for Settings
- Changed from `Settings` scene (which uses `SettingsLink`) to `Window("Settings", id: "settings")` with `openWindow(id: "settings")`
- **Result:** Still crashes

### 2. Inline settings within MenuBarExtra (view swap at App level)
- Removed the Settings window entirely
- Added `@State private var showingSettings` to `DICTATRApp`
- Used conditional rendering in `MenuBarExtra` body: `if showingSettings { settingsVStack } else { MenuBarView }`
- Passed `showingSettings` as `@Binding` to `MenuBarView`
- **Result:** Still crashes

### 3. Inline settings within MenuBarView (view swap at View level)
- Moved `showingSettings` as `@State` into `MenuBarView` itself
- No more view swapping at the `DICTATRApp` scene level
- Settings panel rendered inside MenuBarView's own body
- **Result:** Still crashes

### 4. Fixed button hit targets
- Changed from `.buttonStyle(.borderless)` to `.buttonStyle(.plain)` with `.contentShape(Rectangle())` and `.padding(.vertical, 4)`
- **Result:** Still crashes (issue was never the button — it's the settings VIEW that crashes)

### 5. Replaced Button with onTapGesture
- Removed `Button` entirely for menu rows, used `HStack` + `.onTapGesture`
- **Result:** Still crashes

### 6. Removed LaunchAtLogin.Toggle
- Removed `import LaunchAtLogin` from SettingsView.swift
- Replaced `LaunchAtLogin.Toggle("Launch at login")` with a plain text placeholder
- **Rationale:** `SMAppService` (used by LaunchAtLogin) likely crashes in unsigned apps
- **Result:** Still crashes (though this was the strongest hypothesis)

### 7. Deferred Quit with DispatchQueue.main.async
- Wrapped `NSApplication.shared.terminate(nil)` in `DispatchQueue.main.async { ... }`
- **Result:** Not related to Settings crash, but done for robustness

## What Has NOT Been Tried

### A. Completely empty settings view
- Replace `GeneralSettingsView()` with a minimal `Text("Settings")` to confirm the crash is in the view content vs. the view transition itself

### B. Remove KeyboardShortcuts.Recorder
- `KeyboardShortcuts.Recorder("Toggle Dictation:", name: .toggleDictation)` may also crash in an unsigned app context

### C. Strip GeneralSettingsView down incrementally
- Remove sections one at a time to isolate which component crashes:
  1. Remove Hotkey section (KeyboardShortcuts.Recorder)
  2. Remove Transcription section (Picker)
  3. Remove Behavior section (Toggle + Stepper)
  4. Remove System section (already just text now)

### D. Check crash logs
- Look in `~/Library/Logs/DiagnosticReports/` or Console.app for DICTATR crash reports
- This would immediately show the exact crash location

### E. Test from Xcode with debugger attached
- Run the DMG version from Xcode's debugger to catch the crash in the call stack
- Or: run the Xcode-built version (not DMG) and see if Settings works there

### F. Use .menu style instead of .window style
- `MenuBarExtra` with `.menuBarExtraStyle(.menu)` uses native NSMenu items
- No SwiftUI view rendering issues, but loses custom layout

## Key Files
- `Sources/DICTATR/Views/SettingsView.swift` — GeneralSettingsView definition
- `Sources/DICTATR/Views/MenuBarView.swift` — menu bar UI with Settings button
- `Sources/DICTATR/DICTATRApp.swift` — app entry point, MenuBarExtra scene
- `create-dmg.sh` — DMG packaging script (manually bundles .app)

## Notes
- The app works perfectly when run from Xcode (Cmd+R)
- The crash only happens in the DMG-distributed manually-bundled version
- All other buttons (Start Dictation, History, Grant Accessibility, Quit) work fine
- The dictation/transcription functionality works correctly
