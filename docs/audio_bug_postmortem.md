# Audio Bug Postmortem: Bluetooth Headphone Recording Failure

**Status:** RESOLVED in v1.3 (2026-03-09)
**Files:** `Sources/DICTATR/AudioRecorder.swift`, `Sources/DICTATR/AppState.swift`

---

## The Bug

When using Bluetooth headphones (AirPods 3, Bose, etc.), dictation silently fails. The user presses F5, sees "Recording..." with a counting timer, speaks, presses F5 again, and gets no transcript. No error is shown. The audio is lost.

### Root cause: Bluetooth AAC-to-HFP codec switch

Bluetooth headphones use AAC codec (stereo, output-only) for playback. When the microphone activates, they switch to HFP codec (mono, mic-enabled). During this switch (~100-500ms), `AVAudioEngine`'s `inputNode.outputFormat(forBus: 0)` returns `sampleRate == 0` and `channelCount == 0`.

The sample-rate conversion in the tap callback:
```swift
let frameCount = AVAudioFrameCount(
    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
)
```
computes `Double / 0 = infinity`, which cast to `UInt32` wraps to 0. The `guard frameCount > 0` then silently drops every buffer. The WAV file ends up with a valid header but zero audio frames. WhisperKit returns empty text, and the user sees "No speech detected" -- a misleading diagnosis.

The bug is intermittent because the codec switch timing varies. Sometimes it completes before `startRecording()` reads the format (works fine). Sometimes it hasn't completed yet (silent failure for the entire recording).

### Contributing factors in the original code

- `try? outFile.write(from: convertedBuffer)` swallowed all write errors silently
- No frame counting existed, so there was no way to detect empty recordings
- `AVAudioEngine.configurationChangeNotification` was not observed, so mid-recording device changes caused zombie recordings
- "No speech detected" was shown for both "user was silent" and "hardware captured nothing"

---

## The Failed Fix (v1.1-v1.2): Async Retry Loop

We added a retry loop: if `sampleRate == 0`, wait up to 3x300ms for the codec switch to complete. This required making `startRecording()` `async throws`.

**This made headphone recording worse, not better.** The async change introduced a race condition:

```swift
// AppState.startRecording() -- the broken version
currentState = .recording      // immediate
statusMessage = "Recording..."  // immediate

Task {
    _ = try await audioRecorder.startRecording()  // up to 900ms delay!
    NSSound(named: .init("Tink"))?.play()         // only after await
    recordingIndicator.show(audioRecorder: audioRecorder)  // only after await
}
```

**Three problems:**
1. **Recording indicator delayed** -- shown only AFTER the async call completes (up to 900ms with Bluetooth). User sees "Recording..." status but no timer panel.
2. **F5 toggle race** -- user presses F5 to stop while the async `startRecording()` is still in the retry loop. `toggleRecording()` sees `currentState == .recording` and calls `stopRecordingAndTranscribe()`, but `audioRecorder.isRecording` is `false` (engine hasn't started yet). `stopRecording()` returns nil. The recording is silently abandoned.
3. **State desync** -- `currentState = .recording` is set before the engine starts. If the engine fails, the UI is stuck showing "Recording..." until the Task's catch block runs.

---

## The Actual Fix (v1.3): Synchronous Start + Config Change Recovery

### Core insight

We don't need to wait for a valid format before starting the engine. Starting the engine is what *triggers* the Bluetooth codec switch. We just can't install a tap until the format is valid. The engine itself runs fine without a tap.

### What we did

**1. Reverted `startRecording()` to synchronous (`throws`, not `async throws`)**

Removed the retry loop entirely. The function reads the format once, and branches:

- **Format valid** (built-in mic, or Bluetooth already switched): create converter, install tap, start engine. Normal path.
- **Format invalid** (sampleRate=0, Bluetooth mid-switch): skip tap installation, start the engine anyway. The `configurationChangeNotification` handler installs the tap once the codec switch completes.

**2. Config change handler as the recovery mechanism**

When the Bluetooth codec switch completes, macOS fires `AVAudioEngine.configurationChangeNotification`. Our handler:
1. Removes the old tap (no-op if none was installed)
2. Reads the now-valid format
3. Creates a new converter
4. Installs the tap
5. Restarts the engine

If the format is still invalid when the notification fires (rare transitional state), the handler retries up to 3 times with 200ms delays before giving up.

**3. Reverted AppState to synchronous call**

```swift
do {
    let url = try audioRecorder.startRecording()
    currentState = .recording    // only after engine is running
    statusMessage = "Recording..."
    NSSound(named: .init("Tink"))?.play()
    recordingIndicator.show(audioRecorder: audioRecorder)
} catch {
    // ...
}
```

Everything happens in the same runloop tick as the F5 press. No Task, no async gap.

**4. Kept all the good stuff from the failed fix**

- Frame counting (`_framesWritten`, `_droppedFrames` atomic counters)
- `framesWritten < 800` check at stop -- shows "No audio captured. Check your microphone." instead of sending empty audio to WhisperKit
- `os.Logger` across both `AudioRecorder` and `AppState` (subsystem `com.dictatr`)
- `do/catch` on `outFile.write()` instead of `try?`
- Shared `installTap()` method used by both start and config change recovery

### What we lose

The first ~100-300ms of audio during a Bluetooth codec switch. This is acceptable -- users pause briefly after pressing record, and partial audio is far better than zero audio.

---

## Behavior Matrix

| Scenario | Original (broken) | After retry fix (worse) | After v1.3 fix (current) |
|---|---|---|---|
| Built-in mic | Works | Works | Works |
| Headphones, format valid on start | Works | Works (indicator late) | Works (indicator immediate) |
| Headphones, format zero on start | Silent failure, "No speech detected" | Race condition, recording abandoned | Engine starts, tap installs on config change, first ~200ms lost, rest captured |
| Headphones, format never becomes valid | Silent failure | Throws error after 900ms | "No audio captured. Check your microphone." |
| F5 double-tap during startup | N/A | Broken -- stop before start completes | Safe -- state is synchronous |
| Device change mid-recording | Zombie recording (no audio) | Attempts recovery (untested) | Config change handler reinstalls tap |

---

## Debugging Future Audio Issues

### Console.app

Filter by subsystem `com.dictatr` to see the full recording lifecycle:

**Normal recording (built-in mic):**
```
[AudioRecorder] Recording with input format: 48000.0Hz, 1ch
[AudioRecorder] Engine started (tapInstalled=true, file=dictatr_1741520000.wav)
[AppState]      Recording started -> dictatr_1741520000.wav
[AudioRecorder] Recording stopped: 48000 frames written, 0 frames dropped, 3.2s duration
[AppState]      Recording stopped: 3.2s, 48000 frames, file=dictatr_1741520000.wav
[AppState]      Transcription complete: 42 chars
[AppState]      Paste result: pasted
```

**Bluetooth recovery path:**
```
[AudioRecorder] Input format not ready (sampleRate=0.0) -- Bluetooth codec switch in progress
[AudioRecorder] Engine started (tapInstalled=false, file=dictatr_1741520000.wav)
[AppState]      Recording started -> dictatr_1741520000.wav
[AudioRecorder] Audio configuration changed during recording -- reinstalling tap
[AudioRecorder] Reinstalling tap with new format: 16000.0Hz, 1ch
[AudioRecorder] Recording stopped: 45000 frames written, 0 frames dropped, 3.0s duration
```

**Failed recording (no audio captured):**
```
[AudioRecorder] Input format not ready (sampleRate=0.0) -- Bluetooth codec switch in progress
[AudioRecorder] Engine started (tapInstalled=false, file=dictatr_1741520000.wav)
[AudioRecorder] Recording stopped: 0 frames written, 0 frames dropped, 2.5s duration
[AppState]      No audio captured: 0 frames written in 2.5s -- likely mic/Bluetooth issue
```

### Key log signals to look for

| Log message | Meaning |
|---|---|
| `Input format not ready` | Bluetooth codec switch was in progress at start. Should be followed by a config change + tap reinstall. |
| `Engine started (tapInstalled=false)` | Deferred tap path taken. If NOT followed by "Reinstalling tap", the config change never fired -- audio will be empty. |
| `Format still invalid after config change` | Transitional state. Should retry up to 3 times. If all 3 fail, audio will be empty. |
| `Audio frame dropped (N total)` | Tap is running but producing unconvertible frames. If this count is very high and framesWritten is very low, the converter or format is wrong. |
| `stopRecording() returned nil` | `stopRecording()` was called but `isRecording` was false. Should not happen after v1.3 fix since state is synchronous. If this appears, there's a new state management bug. |

---

## Lessons Learned

1. **Never make a synchronous API async to add a retry loop.** The caller's control flow changes fundamentally. If the original API was synchronous, keep it synchronous and find another recovery mechanism.

2. **UI state and engine state must be set atomically.** Setting `currentState = .recording` before the engine starts creates an impossible state. Always set UI state AFTER the operation succeeds.

3. **AVAudioEngine's `configurationChangeNotification` is the correct mechanism for handling device changes.** Don't poll or retry -- observe the notification and react.

4. **Frame counting is essential.** Without it, there's no way to distinguish "user was silent" from "hardware captured nothing." The `framesWritten < 800` check at stop catches hardware failures that would otherwise produce misleading "No speech detected" messages.

5. **`try?` on I/O operations hides real problems.** Always use `do/catch` with logging. The original `try? outFile.write()` masked every write failure.

6. **Starting the engine triggers the codec switch.** The engine doesn't need a tap to run. Starting it without a tap is valid and useful -- it triggers the hardware state change that makes the tap possible.

---

## Files Involved

- `Sources/DICTATR/AudioRecorder.swift` -- audio engine, tap, format handling, config change recovery
- `Sources/DICTATR/AppState.swift` -- recording lifecycle, state management, transcription pipeline
- `Sources/DICTATR/Views/RecordingIndicatorPanel.swift` -- floating timer overlay (no changes)
- `Sources/DICTATR/TranscriptionEngine.swift` -- WhisperKit transcription (no changes)
- `Sources/DICTATR/PasteManager.swift` -- auto-paste (no changes)
