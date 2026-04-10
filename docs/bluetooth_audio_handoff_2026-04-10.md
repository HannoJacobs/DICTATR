# Bluetooth Audio Handoff - April 10, 2026

## Status

This document is a handoff for another agent investigating DICTATR's current Bluetooth recording regression.

The main corrective point is simple:

- Bluetooth microphone support previously worked in DICTATR with both AirPods 3 and Bose QC45.
- The current failure is therefore a regression or a newly-triggered breakage, not evidence that Bluetooth input is categorically unsupported.

## Current User-Visible Symptom

The user reports that DICTATR no longer records reliably when Bluetooth headphones are connected, and in the latest failures it also stopped being usable after route churn and reconnect attempts.

Observed symptoms include:

- DICTATR showing a recording/loading state but capturing zero frames
- immediate or near-immediate `AVAudioEngineConfigurationChange`
- retries that appear to start but never produce audio
- `no audio captured` after stop

## What Is Confirmed

### 1. Built-in microphone works

Recent DICTATR logs showed successful built-in mic recordings with real captured frames, successful transcription, and successful paste.

This means the app is not globally unable to record.

### 2. Bluetooth input worked previously

This is the most important historical evidence because it rules out the lazy conclusion that "Bluetooth mics do not work in DICTATR."

From:

- [dictatr-20260407-161838-257d42b0.log](/Users/hannojacobs/Library/Application%20Support/DICTATR/Logs/dictatr-20260407-161838-257d42b0.log)

Confirmed successful AirPods 3 recordings on April 8, 2026:

- around lines `957-966`
- around lines `972-981`
- around lines `987-996`
- around lines `1002-1011`
- around lines `1017-1026`
- around lines `1032-1041`

These sessions show:

- `defaultInput=AirPods 3`
- `defaultOutput=AirPods 3`
- `engine started`
- non-zero `frames=...`
- clean stop/transcription flow

Confirmed successful Bose QC45 recordings on April 10, 2026:

- around lines `3243-3254`
- around lines `3256-3271`

These sessions show:

- `defaultInput=Bose QC45`
- `defaultOutput=Bose QC45`
- long recordings with non-zero frames
- successful transcription and paste

One example from the Bose path:

- `duration=193.540s`
- `frames=3092480`

That is not a marginal success. DICTATR clearly worked on Bose Bluetooth input earlier the same day.

## What Failed Later

Later Bose sessions in the same historical log show the route becoming unstable:

- around lines `3273-3308` in [dictatr-20260407-161838-257d42b0.log](/Users/hannojacobs/Library/Application%20Support/DICTATR/Logs/dictatr-20260407-161838-257d42b0.log)

That sequence shows:

- start on Bose
- config change
- engine stops
- retry on default device
- fallback to built-in mic
- built-in override applied
- another config change
- eventual stop with `frames=0`

So there are two distinct truths:

- Bluetooth definitely worked before
- the current recovery path can still collapse into a zero-frame session after route churn

## New Hard Evidence From Today's Unified Log

The most important new evidence came from the unified log around:

- `2026-04-10 16:35:19` to `2026-04-10 16:35:24`

Command used:

```zsh
/usr/bin/log show --style compact --start '2026-04-10 16:35:15' --end '2026-04-10 16:35:25' --predicate '(process == "DICTATR" OR process == "coreaudiod")'
```

This was after DICTATR had already started preferring the MacBook mic when AirPods were the default Bluetooth input.

The key sequence was:

1. DICTATR detects Bluetooth input and prefers built-in mic.
2. DICTATR applies the built-in mic override.
3. `coreaudiod` still performs a Bluetooth profile/configuration change for the AirPods route.
4. DICTATR receives `config change received ... engineRunning=true`.
5. `AudioRecorder.handleConfigurationChange()` removes and reinstalls the tap.
6. AVAudioEngine throws an assertion:

```text
required condition is false: format.sampleRate == inputHWFormat.sampleRate
```

The corresponding stack trace points into DICTATR's config-change recovery:

- [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift#L301)
- [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift#L339)

Specifically:

- `handleConfigurationChange()` gets `newFormat = inputNode.outputFormat(forBus: 0)`
- it calls `installTap(... format: newFormat ...)`
- AVAudioEngine rejects the tap install because the format no longer matches the input hardware format during the route transition

This is the strongest current evidence of an actual DICTATR bug, not just environmental contention.

## Most Likely Current Failure Mode

Current working diagnosis:

- DICTATR's in-place tap reinstall logic during Bluetooth route reconfiguration is not always valid
- after the Bluetooth stack renegotiates the route, the format returned and the hardware input format can temporarily diverge
- when DICTATR tries to reinstall the tap in that window, AVAudioEngine asserts and the recording session is lost

This does not prove that this is the only bug, but it is the clearest actionable one found so far.

## Scope Of Earlier Contention Theory

Earlier in the investigation, Chromium-based browser audio helper processes were present and likely contributed to route churn.

That theory should now be treated as secondary context, not the primary explanation, because:

- there were later checks with no live Chromium audio helpers
- the unified log still showed the DICTATR tap-reinstall assertion
- the regression can now be explained without requiring a third-party contender

The hard reset action may still be useful operationally, but it should not be treated as the root fix for the current bug.

## Current Working Tree Changes Relevant To This Investigation

At the time of handoff, the working tree contains uncommitted changes including:

- [Sources/DICTATR/AppState.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AppState.swift)
- [Sources/DICTATR/AudioDeviceDiagnostics.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioDeviceDiagnostics.swift)
- [Sources/DICTATR/Views/MenuBarView.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/Views/MenuBarView.swift)
- [Sources/DICTATR/AudioContentionReset.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioContentionReset.swift)
- [CHANGELOG.md](/Users/hannojacobs/Documents/Code/DICTATR/CHANGELOG.md)
- [README.md](/Users/hannojacobs/Documents/Code/DICTATR/README.md)

Important local change already added:

- DICTATR now prefers the MacBook built-in mic up front when the default input is Bluetooth.

That change does not solve the full issue, because the Bluetooth route reconfiguration can still happen and trigger the bad config-change recovery path.

## Light Suggestion To Investigate Next

This is a suggestion, not a conclusion.

The next agent should consider whether the in-place tap reinstall path in [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift#L319) should exist at all for Bluetooth route churn.

Possible direction to test:

- on config change while recording with Bluetooth route involvement, do not reinstall the tap in place
- instead tear down the engine cleanly and restart recording with a fresh engine after the route settles

Why this is worth testing:

- the unified log shows the in-place reinstall can violate AVAudioEngine's required format assumptions
- a fresh engine start may avoid the mismatched intermediate state entirely

Why this should not be treated as gospel:

- it has not been implemented or validated yet
- the failure could still involve additional timing or device-state issues
- the exact safe restart timing may differ between Bose QC45, AirPods, and built-in fallback scenarios

## Recommended Investigation Order

1. Reproduce on a Bluetooth route while capturing both DICTATR log and unified log.
2. Confirm whether the tap reinstall assertion still reproduces on current code.
3. Evaluate whether the reinstall branch in [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift#L319) should be removed or bypassed for Bluetooth-related config changes.
4. If testing a restart-based recovery, verify on:
   - AirPods input + output
   - Bose input + output
   - Bluetooth output with built-in mic input
5. Keep the historical evidence in view and avoid reframing the issue as "Bluetooth never worked."

## Bottom Line

The current evidence supports this handoff summary:

- Bluetooth dictation used to work in DICTATR.
- The current regression includes a concrete app-side failure in config-change recovery.
- The most promising next idea is to question whether in-place tap reinstall should exist for Bluetooth route reconfiguration, but that remains a hypothesis to test, not a final diagnosis.
