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

On first launch the WhisperKit model downloads. DICTATR now prefers a faster English-only
model on the affected M1 Mac class instead of WhisperKit's heavier large-v3 default, because
that default was taking multiple minutes to compile after installs and cache resets.
After an install, update, or cache reset, the first CoreML/Apple Neural Engine compile can
still take time, but it should no longer block behind the slowest known default path on this Mac.

---

## Distributing as a DMG

```bash
# 1. Create release.env from release.env.example
cp release.env.example release.env

# 2. Build, sign, verify, and package the ad-hoc app bundle:
bash create-dmg.sh
```

`create-dmg.sh` now archives the real macOS app bundle from Xcode, signs that `.app`,
verifies the code identity, and only then packages `DICTATR.dmg`. It no longer wraps a bare
Mach-O binary into a synthetic app bundle. In this repo, ad-hoc signing is the default and
supported release path.

### Permissions after installing from DMG
The Xcode-run app and the shipped `/Applications/DICTATR.app` are still different app
instances, so the first installed release still needs permissions granted once:
- **Microphone** — prompted automatically on first use, and may need to be re-granted after an ad-hoc reinstall
- **Accessibility** — must grant manually in System Settings → Privacy & Security → Accessibility

Released DMGs from this repo are expected to be ad-hoc signed. Upgrades will still require
Accessibility to be re-enabled after install, and microphone trust may also need to be
re-granted. This tool is built primarily for self-use, and anyone else using the DMG should
follow the on-device permission steps after install.

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

Important: the **app bundle version is not dynamic**. The DMG/app metadata now comes from
[`Sources/DICTATR/Info.plist`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/Info.plist),
so `CFBundleVersion` and `CFBundleShortVersionString` must still be updated manually for
each release, but there is now a single source of truth.

In this repo, "ship a new version" and "full send" mean the same standard: commit everything required for the release, push everything, make the live GitHub release path current, let the website/download flow pick up that live release state, refresh the local DMG/app, reinstall to `/Applications/DICTATR.app`, relaunch it, and verify the installed app from logs. It is not enough to stop at a local DMG or assume GitHub/Pages will catch up later.

**To full send a new version:**

```bash
# 0. Bump version in Sources/DICTATR/Info.plist
#    Update CFBundleVersion and CFBundleShortVersionString

# 1. Expand CHANGELOG.md for that exact version with very verbose notes
#    Minimum enforced by create-dmg.sh:
#    - at least 8 bullet points
#    - at least 1200 characters in the current version section
#    The entry should explain the user-visible regression/fix, root cause,
#    code-path changes, release or permission changes, and concrete verification.

# 2. Create release.env from release.env.example
#    Default supported values in this repo:
#    - DICTATR_CODESIGN_MODE=adhoc
#    - DICTATR_SPCTL_EXPECT=rejected

# 3. Build, sign, verify, and package the DMG
bash create-dmg.sh

# 4. Commit and push the complete release change set
git add <required files>
git commit -m "release: v1.1"
git push

# 5. Install and verify the built app locally
bash install-release.sh

# 6. Create a GitHub release and upload the DMG
gh release create v1.1 DICTATR.dmg \
  --title "DICTATR v1.1" \
  --notes "What changed in this version."
```

`install-release.sh` verifies the installed signature and launch log, checks that the app is
running from `/Applications/DICTATR.app`, confirms the expected version/build, and surfaces
missing Accessibility trust immediately. If Accessibility is missing, it resets the DICTATR
TCC entry and opens the correct System Settings pane instead of silently continuing.

The website download button automatically serves the new file, and the website version label
follows the latest GitHub release automatically.

For a real full send, do not stop after `gh release create`. Confirm that the live download path now resolves to the new DMG, that the website is therefore serving the current release, and that the locally installed `/Applications/DICTATR.app` is the same shipped build you just released.

**First-time GitHub Pages setup** (one-off, already done):
1. Go to repo Settings → Pages
2. Source: Deploy from a branch
3. Branch: `main` / folder: `/docs`
4. Save — site goes live at `https://hannojacobs.github.io/DICTATR/`

**To update the landing page**, edit `docs/index.html`, commit, and push. GitHub Pages
redeploys automatically within ~30 seconds.

### Release config

Use `release.env` as the single local config source for release signing:

```bash
cp release.env.example release.env
```

Required values:

- `DICTATR_CODESIGN_MODE` — `adhoc` for the default supported release flow in this repo
- `DICTATR_SPCTL_EXPECT` — `accepted`, `rejected`, or `skip`

Optional advanced override:

- `DICTATR_CODESIGN_IDENTITY` — only needed if you deliberately switch to `developer_id` mode yourself

The scripts fail fast if the selected mode is misconfigured. In `adhoc` mode they will build,
package, install, and verify the live installed app from launch-log evidence. If the
installed launch actually reports `accessibilityTrusted=no`, treat that as the known local
permission handoff: remind the user to re-enable Accessibility for `/Applications/DICTATR.app`,
then continue verification after the permission is restored. Do not treat that specific
post-install permission reset as evidence that the release itself failed once the installed
app path and version/build are already confirmed.

### Diagnostics Logs

DICTATR now writes persistent per-launch diagnostics logs to:

```bash
~/Library/Application\ Support/DICTATR/Logs/
```

Files are named like:

```bash
dictatr-20260401-205500-ab12cd34.log
latest.log
```

What gets logged:
- Model policy selection, including the effective variant, the WhisperKit default, and the reason for any reliability override
- App launch / reopen with version, build, PID, macOS build, hardware model, bundle path, diagnostics file path, and Accessibility trust status
- Model startup with selected WhisperKit variant, resolved model folder, compiled-cache snapshot, download milestones, per-phase timings, and long-load heartbeats
- Full audio device inventory at launch
- Recording start, input format, config changes, watchdog failures, retries, and force resets
- Stop/transcription/paste/history-save transitions

Normal relaunches now prefer the local cached model folder directly when it already exists,
instead of doing a remote HuggingFace lookup just to rediscover files that are already on disk.

Useful commands:

```bash
tail -f ~/Library/Application\ Support/DICTATR/Logs/latest.log
ls -lt ~/Library/Application\ Support/DICTATR/Logs
rg -n "watchdog|config change|retry|force reset|recording start" ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

If the app keeps relaunching into `Compiling on-device model...` for multiple minutes,
check the logged `effectiveVariant` first. A repeated stall on the old large-v3 default is
now a model-policy bug; a repeated stall on the selected variant is a compiled-cache incident.

Immediate recovery:

```bash
pkill -x DICTATR
rm -rf ~/Library/Caches/com.hannojacobs.DICTATR/com.apple.e5rt.e5bundlecache
open -a /Applications/DICTATR.app
tail -f ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

Expected evidence:
- The next launch should log `compiledCache=missing` before CoreML load starts.
- Newer builds keep the menu available while the model loads in the background, so a slow compile no longer looks like a failed startup.
- If the previous launch died during compile, newer builds also write
  `~/Library/Application Support/DICTATR/Diagnostics/model-load-recovery.json`
  while the compile is in flight and clear the compiled cache automatically on the next launch.

For the full runbook, see [`docs/model_load_stall_runbook.md`](/Users/hannojacobs/Documents/Code/DICTATR/docs/model_load_stall_runbook.md).

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

### Historical gotcha: manually-bundled apps

Older DICTATR builds used a hand-assembled `.app` that wrapped the raw executable. That
distribution path was broken for two reasons:

- Xcode-managed SPM resource bundles were missing
- the shipped app identity was unstable, which broke Accessibility trust persistence

`create-dmg.sh` no longer uses that packaging path. The post-mortem remains useful context if
you ever see an old build or reproduce the issue manually.

Full diagnosis and post-mortem: [`settings-bug.md`](settings-bug.md)

### Button styles in MenuBarExtra(.window)

SwiftUI `Button` inside a `MenuBarExtra(.window)` scene has unreliable hit-testing:
- `.borderless` — hit target is only the text/icon, not the full row
- `.plain` — can dismiss the window before the action fires

**Fix:** use `HStack` + `.contentShape(Rectangle())` + `.onTapGesture` for full-width,
reliable tap targets. See `MenuBarView.swift`.

### Gatekeeper result depends on notarization state

The release scripts verify whatever signing mode you selected in `release.env`. In `adhoc`
mode, Gatekeeper rejection is expected. That is the default shipped behavior for this repo's
DMGs. If you deliberately maintain your own `developer_id` setup locally, the observed
`spctl` result must still match the configured expectation instead of being assumed.

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
