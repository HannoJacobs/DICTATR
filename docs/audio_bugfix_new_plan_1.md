# Audio Bug Fix Plan: Revert Async, Keep Observability

## Context

The original Bluetooth headphone bug: when Bluetooth headphones switch from AAC to HFP codec on mic activation, `sampleRate` can be 0, causing silent recording failures shown as "No speech detected."

Our fix attempt added a retry loop (3x300ms) in `startRecording()`, which required making it `async throws`. This introduced a worse regression: a race condition between UI state (`currentState = .recording` set immediately) and actual recording state (still awaiting inside a Task). The user can press F5 to stop before recording has actually started, the indicator panel shows late, and the Tink sound is delayed. Headphone recording is now completely broken instead of intermittently broken.

The fix: revert `startRecording()` to synchronous `throws`, remove the retry loop, and rely on the config change handler + frame counting (which we already built) to handle the codec switch gracefully.

## Files to Modify

1. `Sources/DICTATR/AudioRecorder.swift`
2. `Sources/DICTATR/AppState.swift`

## Changes

### 1. AudioRecorder.swift - Revert startRecording() to synchronous

**Remove the retry loop (lines ~66-76):**
- Delete the `for attempt in 0..<3` loop and the `try await Task.sleep` calls
- Remove `async` from the method signature: `func startRecording() throws -> URL`

**Keep the format validation, but make it non-fatal:**
- If `sampleRate == 0 || channelCount == 0` after reading the input format, log a warning but do NOT throw
- Still start the engine and install the tap
- The tap callback will drop frames (frameCount computes to 0), which is fine because:
  - `_droppedFrames` counter tracks this
  - The config change handler will fire when the codec switch completes and reinstall the tap with a valid format
  - If the format never recovers, `framesWritten < 800` catches it at stop time

**In the tap callback (~line 111-158):**
- Keep the existing `guard frameCount > 0 else { _droppedFrames increment; return }` logic -- this safely handles the zero-sampleRate period
- No changes needed here

**Keep everything else we added:**
- Frame counting (`_framesWritten`, `_droppedFrames`)
- Error logging (os.Logger)
- Config change handler (configurationChangeNotification observer)
- `do/catch` on `outFile.write()` instead of `try?`
- Frame stats logging at stop

### 2. AppState.swift - Remove Task wrapper from startRecording()

**In startRecording() (~lines 164-185):**
- Call `audioRecorder.startRecording()` directly (synchronous, no Task wrapper)
- Set `currentState = .recording` AFTER successful start (not before)
- Play Tink sound immediately after start
- Show recording indicator immediately after start
- Wrap in do/catch for error handling

The method becomes straightforward:
```swift
func startRecording() {
    do {
        let url = try audioRecorder.startRecording()
        currentState = .recording
        statusMessage = "Recording..."
        errorMessage = nil
        NSSound(named: .init("Tink"))?.play()
        recordingIndicator.show(audioRecorder: audioRecorder)
    } catch {
        currentState = .idle
        errorMessage = error.localizedDescription
    }
}
```

**No changes to stopRecordingAndTranscribe()** -- the frame count check (`framesWritten < 800` showing "No audio captured") is already correct.

## Why This Works

| Scenario | Behavior after fix |
|---|---|
| Built-in mic | Works as before (format is always valid) |
| Headphones, format valid on start | Works -- format is good, tap captures audio immediately |
| Headphones, format zero on start | Engine starts, tap drops frames briefly, config change handler fires when codec switch completes, reinstalls tap with valid format, audio captures from that point. First ~200-500ms of audio lost but recording recovers. |
| Headphones, format never recovers | Tap drops all frames, `framesWritten < 800` at stop triggers "No audio captured. Check your microphone." -- correct diagnosis instead of misleading "No speech detected" |
| Device change mid-recording | Config change handler reinstalls tap -- same as before |
| F5 toggle race | Eliminated -- startRecording() is synchronous, state is consistent |

## What We Lose

- The retry loop's ability to wait for a valid format before starting. But this is acceptable because:
  - The config change handler provides the same recovery, just after recording starts
  - The first fraction of a second of audio may be lost, but users typically don't start speaking the instant they press F5
  - No race conditions

## Verification

1. Build and run the app
2. Test with built-in mic: F5 to record, speak, F5 to stop -- should transcribe normally
3. Test with AirPods connected:
   - F5 to start -- recording indicator should appear immediately (no delay)
   - Speak for a few seconds, F5 to stop -- should transcribe
   - Check Console.app (filter `com.dictatr`): look for config change events and frame stats
4. Test rapid F5 toggle with AirPods: press F5, then F5 again within ~500ms -- should not crash or hang, should show "Recording too short" or similar
5. Test with AirPods, very short recording (~1s): verify audio is captured (config change handler should have recovered by then)
