# Audio Bugfix Plan v3: Revert to Synchronous Recording + Config Change Recovery

## Root Cause Summary

The original bug: Bluetooth headphones switch from AAC to HFP codec when the mic activates, briefly reporting `sampleRate=0`. This causes the sample-rate conversion to compute `frameCount=0`, silently dropping all audio.

Our fix (async retry loop) made things worse: `startRecording()` became `async throws`, introducing a race condition where the UI shows "Recording..." but the engine hasn't started yet. If the user presses F5 to stop during the retry window, `stopRecording()` sees `isRecording == false` and returns nil -- the recording is abandoned. The recording indicator also shows late (after up to 900ms).

## The Fix: Option A+B from the Post-Mortem

Make `startRecording()` synchronous again. If the input format is invalid (sampleRate=0), start the engine anyway without a tap and let `configurationChangeNotification` install the tap once the Bluetooth codec switch completes. All existing improvements (frame counting, logging, error messages) are preserved.

---

## Changes

### 1. AudioRecorder.swift -- Make `startRecording()` synchronous again

**Revert signature from `async throws` to just `throws`:**

```swift
func startRecording() throws -> URL {
```

**Replace the retry loop (lines 62-81) with a two-path start:**

```swift
let inputFormat = inputNode.outputFormat(forBus: 0)
let formatValid = inputFormat.sampleRate > 0 && inputFormat.channelCount > 0

if formatValid {
    Self.logger.info("Recording with input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")
} else {
    Self.logger.warning("Input format not ready (sampleRate=\(inputFormat.sampleRate)) -- will recover via config change")
}
```

**If format is valid:** create converter + install tap as today (no change to tap logic).

**If format is invalid:** skip converter creation and tap installation entirely. Just start the engine. The config change handler will install the tap once the format becomes valid.

```swift
if formatValid {
    // ... create converter, install tap, write to file (existing logic) ...
}
// If format is invalid, we start the engine with no tap.
// configurationChangeNotification will fire when Bluetooth settles,
// and handleConfigurationChange() will install the tap at that point.

do {
    try engine.start()
} catch {
    // ... cleanup ...
    throw error
}
```

The key: `engine.start()` works even without a tap installed. Starting the engine is what triggers the Bluetooth codec switch. Once the switch completes, macOS fires `AVAudioEngine.configurationChangeNotification`, and our existing handler picks it up.

**Store targetFormat and outputFile as instance properties** so `handleConfigurationChange()` can access them even when no tap was installed at start:

```swift
private var targetFormat: AVAudioFormat?  // add to class properties
```

Set it during `startRecording()` (before the format-valid branch), and use it in `handleConfigurationChange()` (already passed as a parameter today -- this just avoids needing to recreate it).

### 2. AudioRecorder.swift -- Harden `handleConfigurationChange()`

The existing handler already does the right thing (reads new format, creates converter, installs tap). Two small fixes:

**a) Handle the "no tap was installed at start" case:**

Currently the handler calls `inputNode.removeTap(onBus: 0)` unconditionally. If no tap was installed (because format was invalid at start), this is harmless -- `removeTap` on a bus with no tap is a no-op. No change needed here.

**b) Add a delayed retry if format is still invalid:**

If the config change fires but the format is _still_ invalid (rare transitional state), schedule one more check after 200ms instead of giving up:

```swift
guard newInputFormat.sampleRate > 0, newInputFormat.channelCount > 0 else {
    Self.logger.warning("Format still invalid after config change, scheduling retry...")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.handleConfigurationChange(targetFormat: targetFormat)
    }
    return
}
```

Add a retry counter (max 3) to prevent infinite loops if the device is truly gone.

### 3. AppState.swift -- Remove the Task wrapper from `startRecording()`

**Revert `startRecording()` to call audioRecorder synchronously:**

```swift
private func startRecording() {
    guard transcriptionEngine.isModelLoaded else {
        errorMessage = "Model is still loading. Please wait."
        return
    }

    do {
        _ = try audioRecorder.startRecording()
    } catch {
        errorMessage = "Failed to start recording: \(error.localizedDescription)"
        return
    }

    // These all happen immediately, in the same runloop tick as F5 press:
    currentState = .recording
    statusMessage = "Recording..."
    errorMessage = nil
    NSSound(named: .init("Tink"))?.play()
    recordingIndicator.show(audioRecorder: audioRecorder)
}
```

This fixes all three regression bugs:
- Recording indicator shows immediately (no async gap)
- F5 toggle is safe (state and engine are in sync -- both set in the same synchronous call)
- Tink sound plays immediately

**Move `currentState = .recording` to AFTER `startRecording()` succeeds** so state is never set if the engine fails to start.

### 4. No other file changes needed

- `RecordingIndicatorPanel.swift` -- no changes
- `TranscriptionEngine.swift` -- no changes
- `PasteManager.swift` -- no changes

---

## How This Fixes Each Scenario

| Scenario | Before (broken) | After this fix |
|---|---|---|
| Built-in mic | Works | Works (no change) |
| Headphones, format valid at start | Works but indicator shows late | Works, indicator shows immediately |
| Headphones, format zero at start | Race condition, recording abandoned | Engine starts, tap installed via config change handler when codec switch completes. First ~200ms of audio lost, rest captured. |
| F5 pressed quickly during startup | stopRecording() returns nil, recording abandoned | Synchronous -- stop always works because isRecording is set only after engine starts |
| Device disconnected mid-recording | Config change handler attempts recovery | Same -- handler reads new format, reinstalls tap |
| No mic at all | Throws after 900ms retry | engine.start() may throw immediately, or config change never fires -- frame count check catches it at stop with "No audio captured" |

## What We Lose

- The first ~100-300ms of audio during a Bluetooth codec switch. This is acceptable -- users typically pause briefly after pressing the record button anyway, and partial audio is far better than zero audio.

## Testing

1. **Built-in mic** -- record, stop, verify transcript (regression check)
2. **AirPods connected** -- record, stop, verify transcript works
3. **AirPods connected, quick F5 toggle** -- press F5, immediately press F5 again within 500ms. Should either produce a "Recording too short" message or a valid (short) transcript. Must NOT silently fail or get stuck.
4. **Console.app** -- filter `com.dictatr`, verify log shows either "Recording with input format" (normal path) or "Input format not ready... will recover via config change" followed by "Reinstalling tap with new format" (recovery path)
5. **Disconnect headphones mid-recording** -- should see config change log, recording should either recover with built-in mic or show "No audio captured" at stop

## Implementation Order

1. Revert `startRecording()` to synchronous (`throws`, not `async throws`)
2. Add the two-path logic (format valid vs invalid)
3. Store `targetFormat` as instance property
4. Add retry counter to `handleConfigurationChange()`
5. Update `AppState.startRecording()` to remove Task wrapper
6. Build and test with built-in mic (regression)
7. Test with AirPods
