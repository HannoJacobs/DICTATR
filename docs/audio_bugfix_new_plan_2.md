# Audio Bug Fix Plan v2

## Root cause recap

The original bug: Bluetooth headphones switch from AAC to HFP codec when the mic activates, causing `inputNode.outputFormat(forBus: 0)` to return `sampleRate == 0`. The sample rate conversion `Double / 0 = infinity → UInt32 = 0` silently drops every buffer.

The attempted fix (retry loop) made it worse: `startRecording()` became `async`, which introduced a race condition between UI state (`.recording` set immediately) and actual recording (starts up to 900ms later). Users who press F5 → speak → F5 hit a state where `stopRecording()` is called before recording actually started. The recording indicator also shows late.

## The fix: synchronous start + deferred tap installation

The key insight: we don't need to wait for a valid format before starting the engine. We just can't install a tap or create a converter until the format is valid. The engine itself can run fine — and starting it is what *triggers* the Bluetooth codec switch in the first place.

### Changes to AudioRecorder.swift

#### 1. Revert `startRecording()` from `async throws` back to `throws`

Remove the retry loop entirely. The function must be synchronous so the caller gets immediate feedback.

#### 2. Split into two paths based on format validity

```
startRecording() throws -> URL:
    create engine, get inputFormat

    if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0:
        // Happy path — install tap immediately (current working code)
        create converter, create file, install tap, start engine
    else:
        // Bluetooth codec switch in progress
        // Start engine WITHOUT a tap — this triggers the codec switch
        // The configurationChangeNotification handler will install the tap
        start engine
        log: "Waiting for Bluetooth codec switch, tap will install on config change"

    // Either way: set isRecording, start timer, set up config observer
    return fileURL
```

The critical point: the engine starts, the UI updates, the timer counts, and the recording indicator shows — all immediately. Audio capture begins either now (good format) or when the config change fires (Bluetooth).

#### 3. Enhance `handleConfigurationChange` to handle first-time tap installation

Currently it assumes a tap already exists (calls `removeTap` then `installTap`). It needs to also handle the case where no tap was ever installed — i.e., the deferred path from step 2.

The handler already reads the new format, creates a converter, installs the tap, and restarts the engine. It just needs to:
- Also create the output file if it doesn't exist yet (deferred path)
- Skip `removeTap` if no tap was installed
- Guard against the new format ALSO being invalid (log and wait for next notification)

#### 4. Track whether tap is installed

Add a `_tapInstalled` flag (OSAllocatedUnfairLock<Bool>) so `handleConfigurationChange` knows whether to call `removeTap` first. Also needed for `stopRecording()` to know whether to call `removeTap`.

#### 5. Handle the edge case: config change never fires

If the user records for a few seconds and the Bluetooth codec never switches (broken device, weird state), `stopRecording()` will see `framesWritten == 0` and AppState already handles that with "No audio captured. Check your microphone." This is the correct behavior — no silent failure.

### Changes to AppState.swift

#### 6. Revert `startRecording()` to synchronous

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

    currentState = .recording
    statusMessage = "Recording..."
    errorMessage = nil
    NSSound(named: .init("Tink"))?.play()
    recordingIndicator.show(audioRecorder: audioRecorder)
}
```

No `Task`, no `async`. Everything happens on the main thread in order. The state transitions only after `startRecording()` succeeds. The recording indicator and sound play immediately.

This eliminates:
- The F5 toggle race (state is only `.recording` after engine is started)
- The late recording indicator (shows immediately after engine start)
- The late Tink sound

#### 7. No other AppState changes needed

`stopRecordingAndTranscribe()` already handles `framesWritten < 800` correctly. The "No audio captured" message is the right UX for the deferred-tap-never-installed edge case.

## Behavior matrix after fix

| Scenario | Before (original) | After retry fix (current, broken) | After this plan |
|---|---|---|---|
| Built-in mic | Works | Works | Works |
| Headphones, format valid on start | Works | Works (indicator late) | Works (indicator immediate) |
| Headphones, format zero on start | Silent failure, "No speech detected" | Race condition, recording may never start | Engine starts immediately, tap installs on config change, loses first ~100ms of audio, rest captured normally |
| Headphones, format never becomes valid | Silent failure | Throws error after 900ms | Records 0 frames, "No audio captured. Check your microphone." |
| Device change mid-recording | Zombie recording | Attempts recovery (untested) | Same config change handler, now also handles initial install |
| F5 double-tap race | N/A | Broken — stop before start completes | Impossible — state is synchronous |

## File-by-file summary

| File | Changes |
|---|---|
| `Sources/DICTATR/AudioRecorder.swift` | Remove `async` from `startRecording()`. Remove retry loop. Add deferred tap path when format is invalid. Add `_tapInstalled` flag. Update `handleConfigurationChange` to handle first-time tap install. Update `stopRecording` to conditionally remove tap. |
| `Sources/DICTATR/AppState.swift` | Remove `Task` wrapper around `startRecording()`. Move state/indicator/sound to after the `try` call. ~5 lines changed. |

## What we keep from the previous fix

All the good stuff stays:
- Frame counting (`_framesWritten`, `_droppedFrames`)
- Error logging (os.Logger)
- `configurationChangeNotification` handler (enhanced, not removed)
- `framesWritten < 800` check in AppState
- "No audio captured" error message
- `do/catch` on `outFile.write()` instead of `try?`

## What we remove

- The retry loop (lines 66-76 of AudioRecorder.swift)
- The `async` on `startRecording()`
- The `guard inputFormat.sampleRate > 0` that throws `invalidInputFormat` as a hard failure (replaced with deferred tap path)
- The `Task` wrapper in AppState.startRecording()

## Risk assessment

**Low risk**: The synchronous revert in AppState is strictly simpler than the current code. The deferred tap path in AudioRecorder adds a new code path, but it's the same tap-installation logic already in `handleConfigurationChange` — just triggered from a different entry point.

**The one tradeoff**: In the deferred path, the first ~100-500ms of audio (during the codec switch) is lost. This is unavoidable — the hardware literally isn't capturing audio during that window. The previous "working" behavior also lost this audio (the tap was running but producing zero-length frames). The difference is now we recover and capture the rest, instead of silently losing the entire recording.
