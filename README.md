# DICTATR

macOS menu bar dictation app. Press a hotkey, speak, stop — the transcription is
**automatically copied to your clipboard and pasted** into whatever app you were using,
all in one step. Runs 100% on-device using WhisperKit — no cloud, no subscription.

---

## How It Works

```
Hotkey (F5)
    │
    ▼
AudioRecorder          — AVAudioEngine, captures mic at 16kHz mono WAV
    │
    ▼
TranscriptionEngine    — WhisperKit (Apple Neural Engine), on-device Whisper model
    │
    ▼
PasteManager           — copies text to clipboard, simulates Cmd+V into active app
    │
    ▼
DatabaseManager        — saves to SQLite via GRDB (~/Library/Application Support/DICTATR/)
```

Everything is orchestrated by `AppState`, a central `@Observable @MainActor` class.

---

## Tech Stack

| Component | Library |
|---|---|
| Speech-to-text | [WhisperKit](https://github.com/argmaxinc/WhisperKit) |
| Global hotkey | [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) |
| Persistence | [GRDB.swift](https://github.com/groue/GRDB.swift) |
| Launch at login | [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) *(import kept; Toggle UI removed — see gotchas)* |

---

## Build & Run

**Must use Xcode** — `swift build` does not produce a `.app` bundle or embed `Info.plist`.

1. Open `Package.swift` in Xcode (File → Open → select `Package.swift`)
2. Select the **DICTATR** scheme, **My Mac** destination
3. `Cmd+R` to build and run
4. Grant **Microphone** permission when prompted
5. Grant **Accessibility** in System Settings → Privacy & Security → Accessibility

On first launch the WhisperKit model downloads (~500MB–1GB, one time only).

---

## Distributing as a DMG

```bash
# 1. Build Release in Xcode:
#    Product → Scheme → Edit Scheme → Run → Build Configuration: Release → Close → Cmd+B

# 2. Package into a DMG:
bash create-dmg.sh
```

This produces `DICTATR.dmg`. Recipients drag the `.app` to `/Applications` and open it
with right-click → Open on first launch (Gatekeeper bypass for unsigned apps).

### Permissions after installing from DMG
The DMG app has a different code identity from the Xcode-run version. Recipients must
re-grant both permissions:
- **Microphone** — prompted automatically
- **Accessibility** — must grant manually in System Settings → Privacy & Security → Accessibility

---

## Publishing a new release (GitHub Releases + Pages)

The website at `https://hannojacobs.github.io/DICTATR/` always serves the **latest** release
DMG. The download button URL is stable — it never needs updating:
```
https://github.com/HannoJacobs/DICTATR/releases/latest/download/DICTATR.dmg
```

The website's visible version label is also dynamic now: `docs/index.html` fetches the
latest GitHub release and displays its `tag_name`. No manual website version bump is needed
for normal releases.

Important: the **app bundle version is not dynamic**. The DMG/app metadata comes from the
hardcoded `Info.plist` block inside `create-dmg.sh`, so `CFBundleVersion` and
`CFBundleShortVersionString` must be updated manually for each release.

**To ship a new version:**

```bash
# 0. Bump version in create-dmg.sh
#    Update CFBundleVersion and CFBundleShortVersionString

# 1. Build Release in Xcode (Cmd+B with Release config)

# 2. Package the DMG
bash create-dmg.sh

# 3. Create a GitHub release and upload the DMG
gh release create v1.1 DICTATR.dmg \
  --title "DICTATR v1.1" \
  --notes "What changed in this version."
```

That's it. The website download button automatically serves the new file, and the website
version label follows the latest GitHub release automatically.

**First-time GitHub Pages setup** (one-off, already done):
1. Go to repo Settings → Pages
2. Source: Deploy from a branch
3. Branch: `main` / folder: `/docs`
4. Save — site goes live at `https://hannojacobs.github.io/DICTATR/`

**To update the landing page**, edit `docs/index.html`, commit, and push. GitHub Pages
redeploys automatically within ~30 seconds.

### Local app version after manual binary swap

If you replace `/Applications/DICTATR.app/Contents/MacOS/DICTATR` directly with a freshly
built binary, the executable code updates but Finder/About may still show the old version
from `/Applications/DICTATR.app/Contents/Info.plist`.

To keep local version reporting aligned with the deployed build, also update:

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion X.Y" /Applications/DICTATR.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString X.Y" /Applications/DICTATR.app/Contents/Info.plist
```

---

## Required Permissions

| Permission | Why |
|---|---|
| Microphone | Records voice for dictation |
| Accessibility | Simulates Cmd+V to paste into the active app |

The app is `LSUIElement = true` (no Dock icon). It lives only in the menu bar.

---

## Key Files

```
Sources/DICTATR/
  DICTATRApp.swift              — @main, MenuBarExtra scene + History window scene
  AppState.swift                — central state, pipeline orchestration
  AudioRecorder.swift           — AVAudioEngine, 16kHz mono WAV
  TranscriptionEngine.swift     — WhisperKit wrapper, two-phase download+load
  HotkeyManager.swift           — KeyboardShortcuts listener (F5 default)
  PasteManager.swift            — NSPasteboard + CGEvent Cmd+V simulation
  DatabaseManager.swift         — GRDB SQLite, migrations, search
  DictationRecord.swift         — GRDB model (id, text, duration, createdAt)
  KeyboardShortcuts+Names.swift — defines .toggleDictation shortcut name

  Views/
    MenuBarView.swift           — main popup panel + inline settings panel
    ModelDownloadView.swift     — startup progress screen while model downloads
    OnboardingView.swift        — first-launch permission setup
    HistoryListView.swift       — searchable list of past dictations (separate Window)
    SettingsView.swift          — GeneralSettingsView + AboutSettingsView
    RecordingIndicatorPanel.swift — floating NSPanel overlay during recording
```

---

## Recording Duration Limit

Dictation is capped at **5 minutes per session**. While there is no hard code crash beyond
that, WhisperKit processes audio in 30-second chunks sequentially, so transcription time
scales linearly with recording length:

| Recording length | Approximate transcription time |
|---|---|
| 1 min | ~15–30 s |
| 3 min | ~45–90 s |
| 5 min | ~2–3 min |
| 10 min | ~5+ min (not recommended) |

The menu bar popup shows a live duration counter and progress bar while recording:

- **Green** — 0–3:00 (safe zone)
- **Orange** — 3:00–4:00 (getting long)
- **Red** — 4:00–5:00 (approaching limit)

For longer content, break it into multiple dictation sessions.

---

## Known Limitations & Gotchas

### ⚠️  Bundle.module crash in manually-bundled apps

**Any SPM package that calls `Bundle.module` internally crashes with `EXC_BREAKPOINT` when
distributed via `create-dmg.sh`.** Xcode copies SPM resource bundles into
`Contents/Resources/`; the shell-script bundler does not.

Affected APIs removed or replaced:

| Was | Replaced with | File |
|---|---|---|
| `KeyboardShortcuts.Recorder` | Read-only text display | `SettingsView.swift` |
| `LaunchAtLogin.Toggle` | Removed (needs signed app) | `SettingsView.swift` |

**To re-enable these:** code-sign the app with an Apple Developer certificate. Xcode will
then copy the SPM resource bundles and `Bundle.module` will work.

Full diagnosis and post-mortem: [`settings-bug.md`](settings-bug.md)

### Button styles in MenuBarExtra(.window)

SwiftUI `Button` inside a `MenuBarExtra(.window)` scene has unreliable hit-testing:
- `.borderless` — hit target is only the text/icon, not the full row
- `.plain` — can dismiss the window before the action fires

**Fix:** use `HStack` + `.contentShape(Rectangle())` + `.onTapGesture` for full-width,
reliable tap targets. See `MenuBarView.swift`.

### "DICTATR is damaged and can't be opened" after installing from DMG

macOS quarantines unsigned apps downloaded via browser. Right-click → Open does not fix
this variant. Run this in Terminal after dragging to Applications:

```bash
xattr -cr /Applications/DICTATR.app
```

Then open normally.

### Moving the project folder breaks Xcode (no targets / no run destination)

If you move the project to a new folder, Xcode's "Recent Projects" entry still points to
the old location. Opening from there causes Xcode to show **"Cannot build without a run
destination"** and the scheme list will be empty with no targets.

**Fix:** open the project fresh by double-clicking **`Package.swift`** in Finder (or
File → Open → select `Package.swift`). Do not open via Xcode's recent projects list after
a move.

### Model memory appears low in Activity Monitor

The WhisperKit model runs on Apple's Neural Engine using unified memory. This memory is
**not attributed to the process** in Activity Monitor's RSS column. Seeing ~95MB for
DICTATR while the model is loaded is correct and expected. The app is not cloud-connected.

---

## Crash Diagnosis

Crash logs are written to `~/Library/Logs/DiagnosticReports/DICTATR-*.ips`.

Quick parse:
```bash
cat ~/Library/Logs/DiagnosticReports/DICTATR-*.ips | \
  python3 -c "
import sys, json
data = sys.stdin.read()
crash = json.loads(data.split('\n', 1)[1])
for t in crash.get('threads', []):
    if t.get('triggered'):
        for i, f in enumerate(t['frames'][:20]):
            idx = f.get('imageIndex', -1)
            name = crash['usedImages'][idx]['name'] if idx >= 0 else '???'
            print(i, name, '+', f.get('imageOffset',''), ' ', f.get('symbol',''))
"
```
