# Audio Follow-up Postmortem: Crash Fixes and Reconnect Loop

**Status:** Seems improved in `v1.11`, but should be treated as "working in current testing" rather than permanently resolved.
**Files:** `Sources/DICTATR/AudioRecorder.swift`, `Sources/DICTATR/AppState.swift`, `create-dmg.sh`
**Related doc:** `docs/audio_bug_postmortem.md`

---

## Why this document exists

This is the follow-up to the earlier Bluetooth/headphone postmortem. The original document explains the first wave of fixes through `v1.4`.

This document covers the later failures that showed up after that:

- CoreAudio crashes during teardown when the system had already stopped the engine
- A reconnect loop where retries technically succeeded, but `AVAudioEngineConfigurationChange` fired again immediately and tore the engine down again

The goal here is to preserve the attempt history. If the problem comes back, this document should answer:

1. What did we change?
2. What actually helped?
3. What looked promising but was incomplete?
4. What assumptions are we currently relying on?

---

## Symptom cluster

### Symptom A: Crash on teardown

When macOS stopped the audio engine internally after a route/configuration change, DICTATR could still hit a use-after-free crash while tearing the engine down.

Confirmed failure mode:

- `AVAudioEngineConfigurationChange` fires
- CoreAudio has internal blocks still queued
- DICTATR releases `audioEngine` immediately
- CoreAudio later touches an internal engine object via an unretained pointer
- Process crashes with `EXC_BAD_ACCESS`

### Symptom B: "Reconnecting..." loop

After the crash fix was deployed, recording sometimes entered a retry loop:

- retry starts successfully
- engine starts successfully
- a config-change notification arrives almost immediately
- recorder tears everything down again
- AppState retries
- repeat until retry cap is reached

The important observation is that the retry was not failing to start. The engine started. The loop came from treating every config-change notification as fatal.

---

## Timeline of attempts

## `v1.8` - Safe teardown and retry cap

### Edits made

- Removed a force unwrap on `inputNode.audioUnit`
- Guarded `removeTap` and `stop()` with `engine.isRunning`
- Debounced rapid config-change notifications
- Capped retries at 4
- Fell back to the built-in mic after repeated failures

### What worked

- Reduced some obvious crash paths
- Prevented unbounded retry behavior
- Improved behavior when the default Bluetooth route was genuinely broken

### What did not work

- It did **not** solve the CoreAudio use-after-free crash
- Guarding teardown with `engine.isRunning` avoided touching dead engines, but it also left a gap:
  when the system had already stopped the engine, DICTATR could still release it immediately

### Why it was incomplete

The real issue was not just "don't stop an already stopped engine." The real issue was "don't deallocate the engine immediately after CoreAudio/system stop."

---

## `v1.9` - Zombie-delay deallocation in `forceReset()`

### Edits made

- Added a delayed strong reference ("zombie") in `forceReset()`
- Held the engine alive for 200 ms before ARC release

### What worked

- Addressed the confirmed crash path where `forceReset()` released an engine that CoreAudio still had queued work against
- This was the first fix that directly matched the crash report

### What did not work

- The protection only existed in `forceReset()`
- `stopRecording()` still had a path that could release the engine immediately

### Why it was incomplete

There were two teardown paths, not one. `forceReset()` was fixed, but `stopRecording()` still had the same underlying release timing problem.

---

## `v1.10` - Apply zombie-delay to `stopRecording()`

### Edits made

- Extended the delayed-engine-release logic to `stopRecording()`
- Covered the case where the system had already stopped the engine before the user stopped recording

### What worked

- Closed the second use-after-free gap
- Brought `stopRecording()` in line with `forceReset()`

### What did not work

- This did **not** fix the reconnect loop
- Retry attempts still got torn down by fast follow-up config-change notifications

### Why it was incomplete

`v1.10` fixed deallocation timing, but the reconnect loop was a separate logic problem:
we were still assuming that every `AVAudioEngineConfigurationChange` meant "the engine is dead, tear down immediately."

---

## `v1.11` - Ignore transient config-change notifications when engine is still running

### Edits made

- Changed `handleConfigurationChange()` to only tear down when `engine.isRunning == false`
- Added `releaseEngineWithZombieDelay()` helper and used it from both `forceReset()` and `stopRecording()`
- Kept the existing retry/watchdog behavior in `AppState`

### What worked in testing

- The reconnect loop was explained by logs showing this sequence:
  - retry started
  - engine started
  - config-change notification arrived around 50-90 ms later
  - teardown happened even though the engine was still running
- Ignoring that notification while the engine is still running removes the immediate self-inflicted reset

### What this fix assumes

- A config-change notification with a still-running engine is usually a transient route-settle event, not a fatal state
- If that assumption is wrong and the engine is "running but useless," the no-audio watchdog should catch it later

### Remaining uncertainty

This seems like the right fix based on the logs we captured, but it is still an assumption about macOS behavior. If a future device/OS version produces a case where:

- the engine remains `isRunning == true`
- the route really is broken
- and the watchdog path is too slow or too coarse

then this may need another iteration.

---

## Current behavior summary

| Version | Main idea | What improved | What still failed |
|---|---|---|---|
| `v1.8` | Safer teardown + retry cap | Fewer obvious crashes, bounded retries | Still had immediate engine release after system stop |
| `v1.9` | Zombie-delay in `forceReset()` | Fixed one confirmed CoreAudio crash path | `stopRecording()` still had same release bug |
| `v1.10` | Zombie-delay in `stopRecording()` too | Closed second deallocation gap | Reconnect loop still possible |
| `v1.11` | Ignore config changes if engine still running | Stops self-inflicted reconnect loop in current testing | Not yet proven against every headset / route-change pattern |

---

## Exact code-level changes that matter

### `AudioRecorder.handleConfigurationChange()`

Before `v1.11`, the recorder effectively treated every config-change notification as fatal during recording.

After `v1.11`, the logic is:

- if `audioEngine == nil`: ignore
- if `engine.isRunning == true`: ignore the notification as transient
- if `engine.isRunning == false`: tear down and let `AppState` retry

### `AudioRecorder.stopRecording()`

Before `v1.10`, `stopRecording()` could still do:

- skip teardown work when `engine.isRunning == false`
- immediately set `audioEngine = nil`

After `v1.10` and `v1.11`, both `stopRecording()` and `forceReset()` use the same delayed release helper.

### `AppState.handleRecordingFailure()`

This did not change in `v1.11`, but it matters for understanding the system:

- first retry: same device after 1 second
- later retries: built-in mic fallback
- max retries: 4 attempts, then give up with a clear error

The loop was not here. The loop was caused upstream by `AudioRecorder` repeatedly declaring failure after successful restarts.

---

## What currently seems to work

- Preventing immediate deallocation after system stop by delaying engine release
- Sharing the same delayed-release helper across both teardown paths
- Ignoring config-change notifications when the engine is still running
- Letting the watchdog remain the backstop for "running but no usable audio"

---

## What previously looked reasonable but turned out to be incomplete

- `engine.isRunning` guards by themselves
  - Good for avoiding invalid stop/removeTap calls
  - Not enough to avoid use-after-free

- Retry caps and built-in fallback by themselves
  - Good for user experience and loop control
  - Do not fix crashes caused by teardown timing

- Fixing only `forceReset()`
  - Good first step
  - Incomplete because `stopRecording()` could still release the engine too early

---

## If the problem resurfaces

Pull logs first:

```bash
/usr/bin/log show --info --last 10m --style compact \
  --predicate 'subsystem == "com.dictatr" && (category == "AppState" || category == "AudioRecorder")'
```

### Important signals

| Log message | Interpretation |
|---|---|
| `Config change received but engine is still running — ignoring transient route-settle notification` | Expected `v1.11` behavior |
| `Audio configuration changed during recording and engine stopped — tearing down for fresh start` | The system really stopped the engine; retry path should start |
| Repeated `Recording auto-stopped: Audio device changed. Reconnecting...` with successful engine starts in between | Reconnect loop is back |
| `Force-resetting audio recorder` right after a config change | Fatal path taken |
| `Watchdog: recording for 5s with only N frames` | Engine stayed alive but no usable audio arrived |

### Questions to ask if it happens again

1. Did the engine actually stop, or did we just get another transient config-change notification?
2. Did the watchdog fire, or did we tear down before audio had a chance to stabilize?
3. Was the retry on default device, or already on built-in mic?
4. Did the issue happen only with one headset model, or also with built-in mic / wired audio?

---

## Present conclusion

The current hypothesis is:

- `v1.9` and `v1.10` fixed the deallocation crash
- `v1.11` fixed the reconnect loop by distinguishing "notification arrived" from "engine actually died"

That hypothesis matches the logs we captured and the current testing results.

What is still not proven is whether every future route-change edge case can be modeled with the same rule. If this regresses, start by assuming the failure is either:

1. another teardown timing path we still missed, or
2. a new class of config-change event where `engine.isRunning` is not enough to distinguish healthy from unhealthy state
