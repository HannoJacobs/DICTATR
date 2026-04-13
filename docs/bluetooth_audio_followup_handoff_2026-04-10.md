# Bluetooth Audio Follow-Up Handoff - April 10, 2026

## Purpose

This document is a verbose follow-up handoff for the Bluetooth audio investigation in DICTATR.

It records:

- what was already known before this follow-up
- what was changed and shipped in `v1.21`
- what happened immediately after the new build was tested on the same Mac
- what this chat established as the current most likely explanation
- what the next agent should investigate next

This document is meant to be read together with:

- [docs/bluetooth_audio_handoff_2026-04-10.md](/Users/hannojacobs/Documents/Code/DICTATR/docs/bluetooth_audio_handoff_2026-04-10.md)
- [CHANGELOG.md](/Users/hannojacobs/Documents/Code/DICTATR/CHANGELOG.md)
- [Sources/DICTATR/AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift)
- [Sources/DICTATR/AudioDeviceDiagnostics.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioDeviceDiagnostics.swift)
- [Sources/DICTATR/AppState.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AppState.swift)

## Product Constraint

- If the user is using headphones, DICTATR must use the headphones microphone.
- Falling back to the built-in mic is not an acceptable shipped workaround for Bluetooth regressions.

## Short Version

The previous handoff identified one concrete app-side bug:

- DICTATR could hit an AVAudioEngine assertion during Bluetooth route churn because it tried to reinstall the input tap in place during an `AVAudioEngineConfigurationChange`.

That behavior was changed in `v1.21`:

- instead of reinstalling the tap in place during Bluetooth-related config churn
- DICTATR now force-resets the recorder and lets `AppState` drive the reconnect path

That fix appears to have removed the old tap-reinstall assertion path, but it did **not** fully solve the AirPods case.

The newest evidence from this chat suggests a different current bug:

- the new restart rule is too broad
- DICTATR currently treats **any** Bluetooth involvement in the active route as a reason to tear down the session
- as a result, DICTATR repeatedly self-resets before the Bluetooth headset route can settle

Built-in mic still works, but that is diagnostic context rather than an acceptable product fallback.

AirPods currently do not work reliably in the shipped `v1.21` build.

## What Was Already Known Before This Follow-Up

From the earlier handoff:

- DICTATR had historical evidence of working Bluetooth recording on both AirPods 3 and Bose QC45
- built-in mic recording still worked on the affected machine
- the old config-change recovery path in `AudioRecorder.handleConfigurationChange()` could reinstall a tap during a bad format window and trigger:

```text
required condition is false: format.sampleRate == inputHWFormat.sampleRate
```

That earlier handoff correctly framed the issue as:

- a regression
- not proof that Bluetooth recording was never supported

## What This Chat Did Before The Latest Test

This chat started by reading the prior handoff and tracing the relevant recording code.

The key local finding was:

- `AudioRecorder.handleConfigurationChange()` still had an in-place tap reinstall path for running engines

Relevant code at the time:

- [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift)

The reasoning in this chat was:

- `AppState` already had a reconnect / retry path with settle delays and built-in fallback
- the in-place tap reinstall path was the special-case complexity most directly implicated by the earlier unified-log assertion
- by the "should this exist" check, that path was a good candidate for removal or bypass during Bluetooth churn

## What Was Changed And Shipped In v1.21

The app was changed so that `AudioRecorder` no longer tries to reinstall the tap in place when a Bluetooth-involved config change is observed.

The new behavior was:

- if the active route involved Bluetooth
- and a config change arrived while recording
- DICTATR force-reset the recorder and surfaced `Audio device changed. Reconnecting...`
- then `AppState` handled the retry flow

Supporting code:

- [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift#L297)
- [AudioDeviceDiagnostics.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioDeviceDiagnostics.swift#L25)

This was released as:

- `DICTATR v1.21`
- GitHub release: [v1.21](https://github.com/HannoJacobs/DICTATR/releases/tag/v1.21)

It was also installed locally to:

- `/Applications/DICTATR.app`

The installed build was verified from the app log as:

```text
version=1.21 build=1.21 bundlePath=/Applications/DICTATR.app executablePath=/Applications/DICTATR.app/Contents/MacOS/DICTATR
```

## What Happened In The New User Test

After `v1.21` was installed, the user tested again and reported:

- headphones / AirPods still did not work
- built-in mic still worked

This led to a fresh log review of:

- `~/Library/Application Support/DICTATR/Logs/latest.log`
- the macOS unified log around the failure window

## What The DICTATR Log Showed

### 1. Built-in mic sessions were still healthy

In `latest.log`, the built-in mic sessions at approximately:

- `2026-04-10 17:00:01`
- `2026-04-10 17:01:14`

showed:

- normal start
- normal tap install
- normal engine start
- healthy watchdog after 5 seconds
- non-zero frames
- successful transcription

So the new build did **not** break built-in recording.

### 2. AirPods attempt entered the new clean-restart path immediately

At approximately:

- `2026-04-10 17:01:45`

the log shows:

- `Bluetooth default input detected — preferring MacBook mic for new recording`
- `useBuiltInMic=true`
- `built-in mic override applied`

But the same session still shows:

- `defaultInput=AirPods 3`
- `defaultOutput=AirPods 3`
- `inputFormat={24000.0Hz/1ch}`

Then almost immediately:

- `config change received ... engineRunning=true ... frames=0`
- `config change forcing clean restart`
- `force reset ... reason=config change during bluetooth route churn`
- `Recording auto-stopped ... Audio device changed. Reconnecting...`

This repeated several times.

### 3. The session never stabilized while AirPods remained involved

The retry loop kept restarting while the log still showed Bluetooth devices as defaults.

The repeated pattern was:

1. start recording with `useBuiltInMic=true`
2. engine starts
3. config change arrives within roughly `0.1s` to `0.5s`
4. recorder force-resets with `frames=0`
5. `AppState` retries
6. same thing happens again

Eventually `AppState` logged:

- `Exceeded max retries`

### 4. Recording recovered only after the defaults moved fully back to built-in devices

Later in the same sequence, around:

- `2026-04-10 17:02:00`

the route snapshot changed back to:

- `defaultInput=MacBook Pro Microphone`
- `defaultOutput=MacBook Pro Speakers`

Then DICTATR recorded successfully again.

That later successful session showed:

- healthy watchdog
- non-zero frames
- successful transcription

So the new build's practical behavior was:

- fail while AirPods remained the active default route
- recover once the machine had fully returned to built-in input and output

## What The Unified Log Added

The unified log slice for:

- `2026-04-10 17:01:44` to `2026-04-10 17:02:02`

showed evidence that Core Audio was still doing meaningful route/default-device transitions during the retry window.

Notable events included:

- `coreaudiod` moving preferred defaults back toward built-in devices
- DICTATR selecting device `79` (`BuiltInMicrophoneDevice`) later in the sequence
- DICTATR eventually starting IO on the built-in mic successfully

Important implication:

- the machine was not permanently stuck in a broken state
- Core Audio was still converging toward the built-in mic path
- DICTATR was repeatedly resetting itself during that convergence window

## The New Important Diagnosis

The current likely bug is different from the one identified in the earlier handoff.

The earlier bug was:

- in-place tap reinstall during Bluetooth churn could assert because the format window was invalid

The current likely bug is:

- the new clean-restart guard is too broad

Specifically, `AudioRecorder` now does:

```swift
let routeInvolvesBluetooth = activeRouteInvolvesBluetooth || AudioDeviceDiagnostics.activeRouteInvolvesBluetooth()
```

and `AudioDeviceDiagnostics.activeRouteInvolvesBluetooth()` currently means:

```swift
defaultInputIsBluetooth() || defaultOutputIsBluetooth()
```

That means DICTATR treats the following as fatal Bluetooth churn:

- Bluetooth input
- Bluetooth output
- or both

That is likely too aggressive for the case:

- output still on AirPods
- input trying to move to built-in mic

In that case, Bluetooth output alone can keep the recorder in the "Bluetooth route" bucket even if the correct fallback input path is still settling.

## Why This Matters

The current logic likely collapses two different situations into one:

### Situation A: genuinely unsafe Bluetooth input / HFP renegotiation

This was the earlier failure mode.

In that case:

- a clean restart may be safer than in-place tap reinstall

### Situation B: Bluetooth output still present while built-in input is becoming active

This appears to be the current AirPods failure mode in `v1.21`.

In that case:

- a config change may be expected and survivable
- tearing down immediately may be the wrong response

## The Most Important "Should This Exist" Question

The current code says, effectively:

- any Bluetooth output involvement is enough to trigger clean reset behavior

That assumption should now be questioned.

The strongest current design question is:

- should `defaultOutputIsBluetooth()` be part of the fatal reset predicate at all?

This may be the wrong abstraction boundary.

The more relevant condition may be narrower, for example:

- Bluetooth input is active
- or the engine input format / selected input device still points at the Bluetooth path
- not merely that the headphones remain the output device

## What This Chat Established

This chat established all of the following:

1. The `v1.21` change did likely remove the previous tap-reinstall assertion path from the AirPods scenario.
2. The shipped build still does not reliably support the AirPods path.
3. Built-in mic recording remains healthy.
4. The current live failure is now most plausibly caused by over-broad restart logic rather than the original tap-reinstall assertion.
5. The newest likely mistake is treating Bluetooth **output** involvement as sufficient reason to tear down a recording session that is trying to fall back to built-in input.

## Suggested Next Investigation

The next agent should investigate this in the following order:

1. Narrow the condition that triggers the clean-reset path in [AudioRecorder.swift](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift#L321).
2. Explicitly test whether `defaultOutputIsBluetooth()` should be excluded from that decision.
3. Re-test these cases separately:
   - AirPods input + AirPods output
   - built-in input + AirPods output
   - fully built-in input + fully built-in output
4. Capture both:
   - `~/Library/Application Support/DICTATR/Logs/latest.log`
   - unified log around the retry window
5. Verify whether the first post-config-change retry can now survive long enough to accumulate non-zero frames while AirPods remain connected as output.

## Concrete Hypothesis To Test Next

The next concrete hypothesis is:

- DICTATR should not force-reset on config change merely because Bluetooth output is still present

More specifically:

- if the recorder is intentionally using the built-in mic fallback
- and the route churn is only reflecting Bluetooth output / aggregate-device cleanup
- then the session may need to be allowed to continue instead of being force-reset immediately

This is still a hypothesis, not yet validated.

## Bottom Line

As of `2026-04-10` after shipping `v1.21`:

- the old Bluetooth tap-reinstall bug was addressed
- the AirPods path is still not fixed
- built-in mic works
- the most likely remaining bug is that DICTATR now overreacts to Bluetooth involvement during the fallback path
- the clean-reset rule should be narrowed, especially around Bluetooth output remaining active while input is transitioning to the built-in mic
