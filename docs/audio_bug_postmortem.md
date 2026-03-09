# Audio Bug Postmortem: Headphone Dictation Failure

## The Original Bug

When using Bluetooth headphones (AirPods 3, Bose), dictation intermittently fails silently. The user presses F5, sees "Recording..." with a counting timer, presses F5 again to stop, and gets no transcript. No error is shown. The audio is lost.

This happens because Bluetooth headphones switch from AAC codec (stereo, output-only) to HFP codec (mono, mic-enabled) when the microphone activates. During this switch, `AVAudioEngine`'s `inputNode.outputFormat(forBus: 0)` can return `sampleRate == 0` and `channelCount == 0`.

When `sampleRate` is 0, this line in the tap callback:
```swift
let frameCount = AVAudioFrameCount(
    Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate
)
```
computes `Double / 0 = infinity`, which cast to `UInt32` becomes 0. The `guard frameCount > 0` then silently drops every buffer. The WAV file ends up with a valid header but zero audio frames. WhisperKit returns empty text, and the user sees "No speech detected" -- the wrong diagnosis.

The bug is intermittent because the codec switch timing varies. Sometimes it completes before `startRecording()` reads the format (works fine). Sometimes it hasn't completed yet (silent failure).

Additionally:
- `try? outFile.write(from: convertedBuffer)` swallowed all write errors silently
- No frame counting existed, so there was no way to detect empty recordings
- `AVAudioEngine.configurationChangeNotification` was not observed, so mid-recording device changes caused zombie recordings
- "No speech detected" was shown for both "user was silent" and "hardware captured nothing"

## Changes We Made

### 1. Input format validation + retry loop (AudioRecorder.swift)
- Added a guard: if `sampleRate == 0 || channelCount == 0`, throw `AudioRecorderError.invalidInputFormat`
- Added a retry loop: wait up to 3x300ms for Bluetooth codec switch to complete
- Made `startRecording()` `async throws` to support the retry sleep

### 2. Frame counting (AudioRecorder.swift)
- Added `_framesWritten` atomic counter (OSAllocatedUnfairLock)
- Added `_droppedFrames` atomic counter
- Increment `_framesWritten` after each successful `outFile.write()`
- Changed `stopRecording()` return type to include `framesWritten`

### 3. Error logging (AudioRecorder.swift)
- Added `os.Logger` with subsystem `com.dictatr`, category `AudioRecorder`
- Log input format at recording start
- Log frame drops (throttled to every 100th)
- Log conversion failures with status and error
- Replaced `try? outFile.write()` with `do/catch` that logs errors
- Log frame stats at recording stop

### 4. Config change handler (AudioRecorder.swift)
- Observe `AVAudioEngine.configurationChangeNotification` during recording
- On notification: remove old tap, read new format, create new converter, reinstall tap, restart engine
- Continue writing to the same output file

### 5. Frame count check in AppState (AppState.swift)
- After stop, if `framesWritten < 800` (~50ms at 16kHz), show "No audio captured. Check your microphone." instead of sending empty audio to WhisperKit

### 6. Async startRecording in AppState (AppState.swift)
- Changed `startRecording()` call to `Task { try await ... }` since AudioRecorder's method is now async
- Set `currentState = .recording` immediately before the Task

## The Regression We Introduced

The headphone recording is now **worse** than before. Before our changes, it at least sometimes worked (when the codec switch happened to complete in time). Now it's completely broken with headphones. Here's why:

### Race condition between UI state and actual recording state

In AppState.startRecording():
```swift
currentState = .recording      // immediate
statusMessage = "Recording..."  // immediate
errorMessage = nil              // immediate

Task {
    do {
        _ = try await audioRecorder.startRecording()  // up to 900ms delay!
        NSSound(named: .init("Tink"))?.play()         // only after await
        recordingIndicator.show(audioRecorder: audioRecorder)  // only after await
    } catch {
        currentState = .idle
        ...
    }
}
```

Problems:
1. **Timer doesn't count**: The recording indicator is only shown AFTER the async `startRecording()` completes. During the Bluetooth retry loop (up to 900ms), the user sees "Recording..." in the menu bar status but NO recording indicator panel with the counting timer.

2. **F5 toggle race**: The user presses F5, sees "Recording..." status. They speak, then press F5 again. `toggleRecording()` sees `currentState == .recording` and calls `stopRecordingAndTranscribe()`. But if the async `startRecording()` hasn't completed yet (still in the retry loop), `audioRecorder.isRecording` is `false`, so `stopRecording()` returns `nil`. The recording is abandoned.

3. **Even without the retry loop**: Making `startRecording()` async means there's always a potential Task scheduling gap between setting `currentState = .recording` and actually starting the engine. The recording indicator, the Tink sound, and the actual audio capture all happen AFTER the await -- not immediately when F5 is pressed.

### Before vs After

| Scenario | Before our changes | After our changes |
|---|---|---|
| Built-in mic | Works | Works |
| Headphones, format valid | Works | Works (but indicator shows late) |
| Headphones, format zero initially | Silent failure (empty audio, "No speech detected") | Recording doesn't start at all, or race condition |
| Device change mid-recording | Zombie recording (no audio) | Attempts recovery, untested |

## What Needs to Happen Next

The core issue is that `startRecording()` should NOT be async. The retry loop was the wrong approach. Instead:

### Option A: Start recording immediately, handle bad format gracefully
- Keep `startRecording()` synchronous (revert to `throws`, not `async throws`)
- Remove the retry loop
- If `sampleRate == 0`, still start the engine and install the tap
- The tap will drop frames (which it did before), but NOW we have:
  - Frame counting to detect empty recordings
  - The config change handler to recover when the format becomes valid
  - The "No audio captured" message instead of "No speech detected"
- This preserves the original behavior (timer counts, indicator shows) while adding detection

### Option B: Use the config change handler as the primary recovery
- Start with whatever format we get (even if zero)
- When the Bluetooth codec switch completes, it fires `configurationChangeNotification`
- The handler reads the now-valid format, reinstalls the tap, and captures audio from that point on
- The first fraction of a second of audio is lost, but the recording recovers

### Option C: Pre-warm the audio engine
- Create and start the AVAudioEngine earlier (e.g., when the app launches or when headphones connect)
- By the time the user presses F5, the codec switch has already happened
- Read the format only after the engine is running and has settled

Option A is the safest -- it's closest to the original behavior, adds no async complexity, and all our other improvements (logging, frame counting, config change handler, better error messages) still work.

## Files Involved

- `Sources/DICTATR/AudioRecorder.swift` -- all audio capture logic
- `Sources/DICTATR/AppState.swift` -- recording lifecycle, UI state, transcription pipeline
- `Sources/DICTATR/PasteManager.swift` -- auto-paste (uses Accessibility permission, unrelated to audio bug)
- `Sources/DICTATR/Views/RecordingIndicatorPanel.swift` -- floating timer overlay
- `Sources/DICTATR/TranscriptionEngine.swift` -- WhisperKit transcription

## Console.app Debugging

Filter by `com.dictatr` subsystem in Console.app to see:
- Input format at recording start (sampleRate, channels)
- Frame drops during recording
- Conversion failures
- Config change events
- Frame stats at recording stop
