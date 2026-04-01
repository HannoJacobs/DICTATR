# Audio Follow-up Postmortem: Crash Fixes and Reconnect Loop

**Status:** Seems improved in `v1.11`–`v1.13`; `v1.15` adds persistent diagnostics so future regressions can be traced from one launch log instead of depending on unified logging alone.
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

## `v1.13` - Retry coalescing and HFP-settle delays (`AppState`)

### Edits made

- Coalesce rapid `handleRecordingFailure` callbacks while a reconnect is already scheduled (Bluetooth HFP storms no longer burn the whole retry budget in one burst).
- Longer delays after route-churn messages (`Audio device changed`, etc.) before retrying; slightly longer built-in fallback delay.
- Tighter failure cap (`> 3` distinct events instead of `> 4`).
- Docs: system log correlation for Bose QC45 HFP incident; app-side recovery notes.

### What this targets

- **Not** a replacement for `v1.11`’s engine-running check — it complements it when the OS really stops the engine and fires many failure callbacks in a short window.
  (Shipped as `v1.13`; `v1.12` on GitHub was the local HTTP transcription server release.)

---

## `v1.15` - Diagnostic visibility release

### Edits made

- Added persistent per-launch logs under `~/Library/Application Support/DICTATR/Logs/`
- Logged app launch/reopen metadata: version, build, PID, OS build, hardware model, bundle path
- Logged full audio device inventory at launch
- Logged recording start/retry/config-change/watchdog/force-reset transitions with route snapshots and frame counters

### What this targets

- The remaining uncertainty from `v1.11`: cases where `engine.isRunning == true` but the route is effectively broken
- Future Bluetooth/HFP bugs that are hard to reconstruct from CoreAudio logs alone
- Faster correlation between "user-visible reconnect loop" and the exact app-side decision path

---

## Current behavior summary

| Version | Main idea | What improved | What still failed |
|---|---|---|---|
| `v1.8` | Safer teardown + retry cap | Fewer obvious crashes, bounded retries | Still had immediate engine release after system stop |
| `v1.9` | Zombie-delay in `forceReset()` | Fixed one confirmed CoreAudio crash path | `stopRecording()` still had same release bug |
| `v1.10` | Zombie-delay in `stopRecording()` too | Closed second deallocation gap | Reconnect loop still possible |
| `v1.11` | Ignore config changes if engine still running | Stops self-inflicted reconnect loop in current testing | Not yet proven against every headset / route-change pattern |
| `v1.13` | Coalesce retry failures + settle delays | Fewer wasted retries during HFP churn; clearer recovery | HFP stack can still be flaky at the OS level |

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

In `v1.11` this was unchanged; **`v1.13`** updates it:

- coalesce duplicate `onRecordingFailed` calls while a reconnect task is already scheduled
- first retry: same device after a delay (longer for route-churn messages)
- later retries: built-in mic fallback with a slightly longer delay
- max distinct failures: 3, then give up with a clear error

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

## System log correlation (Bose QC45 HFP, 2026-03-23 ~14:34)

Captured with a **narrow time window** so the log is not truncated:

```bash
/usr/bin/log show --info --style compact \
  --start '2026-03-23 14:34:20' --end '2026-03-23 14:35:10' \
  --predicate 'process == "DICTATR" OR process == "coreaudiod" OR process == "audiomxd" OR senderImagePath CONTAINS[c] "CoreAudio" OR eventMessage CONTAINS[c] "4361"'
```

### What the system was doing (same PID 4361 throughout)

1. **HFP / BTAudio churn** — `coreaudiod` repeatedly logged:
   - `HFPInputShimDevice: Reconfigure of Output Device required: Request Config change`
   - `HFP shim Requesting Reconfigure output device to Best sample rate After 2sec`
   - `BTAudioInputShimDevice: Cancel Delayed reconfigure of Peer Audio` (debounced reconfigure storm)

2. **AVAudioEngine stopped by the OS, not only by DICTATR** — **before** our `AudioRecorder` “tearing down” line, `AVAudioEngine` already logged:
   - `iounit configuration changed > stopping the engine` → `stop, was running 1`
   - Then ~250ms later: `iounit configuration changed > posting notification` (this is when our handler runs and logs).

3. **Exact alignment at the first failure in the burst** (~14:34:31–14:34:32):

   | Time | Source | Signal |
   |------|--------|--------|
   | 14:34:31.965 | DICTATR | `Engine@…: start, was running 0` |
   | 14:34:31.978 | coreaudiod / BTAudio | `Reconfigure of Output Device required: Request Config change` |
   | 14:34:32.211 | AVAudioEngine | `iounit configuration changed > stopping the engine` |
   | 14:34:32.459 | AudioRecorder | `Audio configuration changed during recording and engine stopped — tearing down for fresh start` |

4. **Transient device loss** — at **14:34:36.069**, `coreaudiod` logged:
   - `HFP shim Reconfigure output audio device skipped, no device available …`
   - Same timestamp: `… IO 1, quality 1, format 1` (shim gave up while peer/device state was inconsistent).

5. **Why taps failed** — DICTATR logged `AVAudioEngineGraph: Failed to create tap, config change pending!` while HFP was still reconfiguring; this matches “0 frames” / watchdog auto-stop, not a logic bug in frame counting alone.

### Takeaway for future debugging

- **`v1.11`’s “ignore config change if engine still running”** targets **transient notifications** while IO is healthy. In this incident, **`engine.isRunning` was false** because **AVAudioEngine had already been stopped by the configuration change** — so teardown was appropriate.
- The underlying driver of the storm is **Bluetooth HFP sample-rate / output reconfiguration** on the Bose route, not a single mistaken `stop()` in app code (though session category flips like `PlayAndRecord` ↔ `MediaPlayback` still appear around preview/output paths and are worth watching).

### App-side recovery (not a reboot)

Apps **cannot** restart macOS. A reboot helps because **time passes** and Core Audio / Bluetooth settle. Mitigations in `AppState`:

- **Coalesce** rapid `onRecordingFailure` callbacks while a reconnect attempt is already scheduled (one HFP burst → one retry “ticket”, not five).
- **Slightly longer delays** after route-churn messages (e.g. “Audio device changed”) before retrying — closer to what a reboot indirectly provides.
- **Tighter cap** on distinct failure events so the UI doesn’t spin through useless retries; fall back to built-in mic and then stop with a clear error.

---

## Present conclusion

The current hypothesis is:

- `v1.9` and `v1.10` fixed the deallocation crash
- `v1.11` fixed the reconnect loop by distinguishing "notification arrived" from "engine actually died"

That hypothesis matches the logs we captured and the current testing results.

What is still not proven is whether every future route-change edge case can be modeled with the same rule. If this regresses, start by assuming the failure is either:

1. another teardown timing path we still missed, or
2. a new class of config-change event where `engine.isRunning` is not enough to distinguish healthy from unhealthy state
