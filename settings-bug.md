# Settings Button Crash — Root Cause Found & Fixed

## TL;DR

**`KeyboardShortcuts.Recorder` crashes when rendered in a manually-bundled `.app` because it
calls `Bundle.module` (an SPM resource bundle accessor) that doesn't exist outside of an
Xcode-managed build.**

This is a whole class of bug that will silently affect ANY SPM package that ships localised
resources when you distribute via a hand-crafted `.app` bundle (like `create-dmg.sh` does).

---

## What Was Happening

Clicking "Settings..." triggered `GeneralSettingsView` to render. That view contained:

```swift
KeyboardShortcuts.Recorder("Toggle Dictation:", name: .toggleDictation)
```

When SwiftUI instantiated this, `RecorderCocoa.init(for:onChange:)` immediately called
`Bundle.module` to load localised strings. In an SPM package `Bundle.module` is a synthesised
accessor that looks up a `.bundle` resource directory next to the executable. Xcode copies
those bundles into `Contents/Resources/` when it builds. The `create-dmg.sh` script wraps a
raw binary and does **not** copy them, so `Bundle.module` triggers a fatal assertion and the
process dies with `EXC_BREAKPOINT / SIGTRAP`.

**Confirmed from crash logs** (`~/Library/Logs/DiagnosticReports/DICTATR-*.ips`):

```
0:  libswiftCore.dylib   _assertionFailure(_:_:file:line:flags:)
1:  DICTATR              NSBundle.module  ← the smoking gun
2:  DICTATR              one-time initialization function for module
...
7:  DICTATR              KeyboardShortcuts.RecorderCocoa.init(for:onChange:)
8:  SwiftUI              PlatformViewRepresentableAdaptor.makeViewProvider(context:)
```

---

## What Was Tried Before Finding the Real Cause

| # | Attempt | Hypothesis | Result |
|---|---|---|---|
| 1 | Separate `Window` scene | `SettingsLink` crashes | Still crashed |
| 2 | Inline settings at `DICTATRApp` level via `@Binding` | Scene-level view swap dismissed window | Still crashed |
| 3 | Inline settings inside `MenuBarView` via local `@State` | No scene-level swap | Still crashed |
| 4 | `.buttonStyle(.plain)` + `.contentShape` | Hit target too small | Not the issue |
| 5 | `onTapGesture` instead of `Button` | Button style dismissed window | Not the issue |
| 6 | Remove `LaunchAtLogin.Toggle` | `SMAppService` crashes in unsigned apps | Good hygiene, NOT the crash |
| 7 | `DispatchQueue.main.async` on quit | Terminate fires before button completes | Not related |

The actual fix wasn't found until crash logs were read from `DiagnosticReports/`.
**Always check crash logs first.**

---

## The Fix

Replaced `KeyboardShortcuts.Recorder` with a plain text display using
`KeyboardShortcuts.getShortcut(for:)`, which does NOT access `Bundle.module`:

```swift
// BEFORE — crashes in manually-bundled app
Section("Hotkey") {
    KeyboardShortcuts.Recorder("Toggle Dictation:", name: .toggleDictation)
}

// AFTER — safe in any distribution method
Section("Hotkey") {
    HStack {
        Text("Toggle Dictation:")
        Spacer()
        Text(currentShortcutLabel)   // uses getShortcut(for:) — no Bundle.module
            .foregroundStyle(.secondary)
    }
}
```

---

## Future Gotcha — The General Rule

> **Any SPM dependency that calls `Bundle.module` internally will crash in a
> manually-bundled `.app`.**

`Bundle.module` is only safe when Xcode manages the entire build, because only Xcode (and
`xcodebuild`) copies SPM resource bundles (`.bundle` directories) into
`YourApp.app/Contents/Resources/`.

When `create-dmg.sh` wraps the binary, the bundle looks like:

```
DICTATR.app/
  Contents/
    MacOS/DICTATR          ← the binary
    Info.plist
    Resources/
      AppIcon.icns
      # ← NO SPM .bundle directories — they were never copied!
```

### Packages with known `Bundle.module` usage (crash risk in manual bundles):

| Package | Problematic API | Safe alternative |
|---|---|---|
| `KeyboardShortcuts` | `Recorder` view | `getShortcut(for:)`, `onKeyUp(for:)` |
| `LaunchAtLogin` | `LaunchAtLogin.Toggle` | Removed; needs signed app anyway |

### How to check if a package uses `Bundle.module`:
```bash
grep -r "Bundle.module" \
  ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/
```

### Permanent fix options (if you want full features back):

1. **Code-sign and notarise** — Xcode manages the build; SPM bundles are copied correctly.
   Requires an Apple Developer account ($99/yr).
2. **Copy SPM bundles in `create-dmg.sh`** — find the `.bundle` dirs in DerivedData and
   copy them into `Contents/Resources/`. Fragile; the paths change per build.
3. **Use only APIs that don't touch `Bundle.module`** — the current approach.

---

## How to Diagnose Future Crashes

1. Reproduce the crash in the DMG-installed version.
2. Open `~/Library/Logs/DiagnosticReports/` — find the latest `DICTATR-*.ips`.
3. Parse with:
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
               print(i, name, f.get('symbol',''))
   "
   ```
4. The crashed thread's frames show exactly which function triggered the fault.
