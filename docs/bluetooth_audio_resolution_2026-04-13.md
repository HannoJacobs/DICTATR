# Bluetooth Audio Resolution - April 13, 2026

**Status:** current canonical Bluetooth investigation and resolution doc

**Update after initial write-up:**

- The recorder/startup fix first shipped as `1.31`, then the bundled version was promoted to `2.0` once the installed build had real headset retest evidence.
- Installed-build AirPods retest evidence was captured in [`dictatr-20260413-175125-2e38e948.log`](/Users/hannojacobs/Library/Application%20Support/DICTATR/Logs/dictatr-20260413-175125-2e38e948.log) with successful session `c89d634e`.
- Installed-build Bose QC45 retest evidence was captured in [`dictatr-20260413-185034-bd0e09bb.log`](/Users/hannojacobs/Library/Application%20Support/DICTATR/Logs/dictatr-20260413-185034-bd0e09bb.log) with successful sessions `4a9c4e7b` and `f03ba0c5`.
- Update from later April 13, 2026 Bose testing: the failure can still become persistent in-session. The newer builds do sometimes recover on later attempts, but that is not reliable enough to describe as a solved non-permanent failure mode. The current canonical view should therefore remain: Bluetooth starts are intermittently recoverable, but the Bose/AirPods HFP promotion race can still poison a run into repeated `captureState=never_started` failures until retry budget is exhausted.
- Final architectural decision: remove `AVAudioEngine` from DICTATR’s production dictation-capture role and replace it with `AVCaptureSession` / `AVCaptureAudioDataOutput`. The old engine path was not just under-instrumented; it was the wrong primitive for the failure mechanism we kept observing.

**Current code paths:** [`Sources/DICTATR/AudioRecorder.swift`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift), [`Sources/DICTATR/AppState.swift`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AppState.swift), [`Sources/DICTATR/CaptureSessionRecorder.swift`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/CaptureSessionRecorder.swift), [`Sources/DICTATR/CaptureDeviceSelection.swift`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/CaptureDeviceSelection.swift)

## Why this document exists

The Bluetooth investigation had already produced multiple historical handoff and postmortem files, but the same questions were still being re-asked:

1. Did Bluetooth ever work in DICTATR?
2. Was the reconnect loop caused by DICTATR, by CoreAudio, or both?
3. Should DICTATR hardcode headset-specific sample rates?
4. Should DICTATR keep using `AVAudioEngine` for dictation at all?

This document is meant to stop that loop. A future agent should be able to read this file, inspect the current code, and continue from the current evidence instead of re-deriving it from old logs and partial memories.

## Installed-app evidence

The currently relevant installed-build log was:

- `~/Library/Application Support/DICTATR/Logs/dictatr-20260413-160948-9879360a.log`
- installed bundle path: `/Applications/DICTATR.app`
- installed version at the time of investigation: `1.30 build 1.30`

There was also an earlier failed launch on the same day:

- `~/Library/Application Support/DICTATR/Logs/dictatr-20260413-160106-adfbc119.log`

### Successful AirPods sessions

The same installed `1.30` build successfully dictated on AirPods in the same launch. The confirmed successful session IDs were:

- `235bbed3`
- `f3febfa5`

Both successful sessions shared the same pattern:

- route at start looked like AirPods input at `24000 Hz` and AirPods output at `48000 Hz`
- DICTATR’s preflight engine input format was already `24000 Hz`
- `engine.start()` completed quickly
- the route collapsed to `24000/24000`
- the first tap callback arrived within about `177 ms`
- frames accumulated normally and transcription succeeded

The successful window around `2026-04-13 16:10:55` also showed the lower-level AUHAL stream formats changing to `24000 Hz` before the recording entered its normal callback flow.

### Failed AirPods sessions

The failed AirPods sessions in the same launch were:

- `60f04043`
- `433a2e66`
- `4e7b83ba`
- `bc07c691`
- `0fdb2137`
- `94ebc35e`
- `3da20684`
- `a82f3e9e`

The earlier failed launch `dictatr-20260413-160106-adfbc119.log` showed the same pattern for:

- `0d335023`
- `82bfe01a`
- `79c67846`
- `16b34b8d`

Across those AirPods failures, the strong discriminant was not the visible route alone. It was the engine graph state.

The failures shared this pattern:

- route at start still looked like AirPods input at `24000 Hz` and AirPods output at `48000 Hz`
- DICTATR’s preflight engine format was `48000 Hz`
- DICTATR installed a tap/converter from that stale format
- `engine.start()` then overlapped the HFP collapse to `24000/24000`
- `AVAudioEngineConfigurationChange` arrived before the first callback
- `captureState=never_started`, `tapCallbackCount=0`, `framesWritten=0`
- DICTATR force-reset and retried

That exact pattern repeated across multiple retries and multiple launches.

## System-log correlation

The good and bad unified-log windows were:

- good window: `2026-04-13 16:10:55–16:10:56`
- bad window: `2026-04-13 16:13:23–16:13:25`

The successful start showed AUHAL moving onto `24000 Hz` and then the session flowed.

The failed start showed:

- `HFPInputShimDevice: Reconfigure of Output Device required: Request Config change`
- AUHAL/graph formats changing underneath the start
- `Engine@... iounit configuration changed > stopping the engine`
- `Engine@... iounit configuration changed > posting notification`
- DICTATR receiving `AVAudioEngineConfigurationChange`
- zero callbacks and zero frames before reset

The key timeline point is that the route can *look* Bluetooth-ready while the engine graph is still stale, and `engine.start()` can itself provoke the HFP reconfiguration that kills the engine before the first callback.

## What this investigation concluded

### 1. Bluetooth dictation definitely worked before

That matters because it rules out the lazy conclusion that “Bluetooth microphones do not work in DICTATR.” Historical logs already showed successful AirPods and Bose dictation, and the April 13 installed build also had two successful AirPods sessions in the same launch.

### 2. The core bug was committing to a stale engine format too early

At investigation time, DICTATR was reading:

- `inputNode.outputFormat(forBus: 0)`

in [`AudioRecorder.swift`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AudioRecorder.swift), treating `sampleRate > 0 && channelCount > 0` as sufficient readiness, and installing the tap before `engine.start()`.

That was too weak for Bluetooth starts. The stale `48000 Hz` preflight format was “valid” by that rule even though the route was still on its way to `24000 Hz`.

### 3. Route quiet was the wrong retry gate

At investigation time, [`AppState.swift`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/AppState.swift) waited for a stable-window interval since the last observed route change before retrying.

The logs showed that was not enough:

- the route could look stable for well over a second
- DICTATR would retry
- the next `engine.start()` would immediately trigger a new HFP reconfiguration
- the engine would stop before the first callback again

So route age had diagnostic value, but it was not a trustworthy success condition.

### 4. There should not be a per-headset sample-rate table

This is the STEC answer.

The correct design is not:

- “AirPods use `24000`”
- “Bose use `16000`”
- “if headset name contains X, use Y”

That logic should not exist at all.

The system should negotiate the Bluetooth profile and rate. DICTATR should either:

- read the live graph correctly and adapt generically, or
- use a higher-level capture primitive that already vends native input format automatically

## Apple sources and what they were used to prove

### [Audio Engine](https://developer.apple.com/documentation/avfaudio/audio-engine)

Used to confirm that `AVAudioEngine` is the advanced real-time graph tool, not the “basic dictation recorder” abstraction.

### [AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)

Used to confirm Apple still exposes a higher-level file-recording API for straightforward microphone capture. This supports the STEC question of whether DICTATR should keep using `AVAudioEngine` for dictation at all.

### [Audio and video capture](https://developer.apple.com/documentation/avfoundation/audio-and-video-capture)

Used to confirm `AVCaptureSession`, `AVCaptureAudioDataOutput`, and `AVCaptureAudioFileOutput` are legitimate capture-session primitives on macOS, not iOS-only ideas.

### [thread 775015](https://developer.apple.com/forums/thread/775015)

Used as the strongest Apple-source support for the capture-session alternative. Apple Media Engineering explicitly pointed to `AVCaptureDevice + AVCaptureSession`, or `AVCaptureAudioDataOutput` as the provider of audio samples, instead of sourcing microphone audio from `AVAudioEngine.inputNode` on macOS.

### [thread 769907](https://developer.apple.com/forums/thread/769907)

Used to support that AirPods playback-versus-play-and-record switching can cause `AVAudioEngineConfigurationChange`. That matches the HFP transition class of failures DICTATR observed.

### [thread 663126](https://developer.apple.com/forums/thread/663126)

Used to support that input and output rates can differ in the engine until a configuration links them, which aligns with the observed `24000` input / `48000` output mixed state before HFP collapse.

### [thread 802904](https://developer.apple.com/forums/thread/802904)

Used to support the principle that when a configuration change occurs, apps need to re-query the formats after the change rather than trusting stale earlier format assumptions.

### [AVAudioRoutingArbiter](https://developer.apple.com/documentation/avfaudio/avaudioroutingarbiter)

Used to establish that macOS has an Apple-supported AirPods Automatic Switching / route-arbitration hinting API. It is not a sample-rate picker, and it is not a Bose-specific solution, but it is appropriate generic system participation for nearby supported Apple/Beats routes.

### [thread 71008](https://developer.apple.com/forums/thread/71008)

Used as additional support that on macOS the engine’s I/O nodes are tied to the system default devices, which is part of why default-route transitions matter to DICTATR’s capture path.

## What changed in the code after this investigation

The current implementation direction is:

- log both `inputNode.inputFormat(forBus: 0)` and `outputFormat(forBus: 0)` before and after engine start
- attach `AVAudioEngineConfigurationChange` observation before `engine.start()`
- start the engine before installing the tap
- install the tap only from a live graph whose input and output formats are both non-zero and equal
- use a startup deadline keyed off the first callback rather than route quiet
- keep route age as diagnostic context, not as the primary retry success condition
- include an internal `AVCaptureSession + AVCaptureAudioDataOutput` comparison backend in-tree behind an internal backend switch

## Decision rule if this still fails

If the installed build still shows the preexisting Bluetooth failure signature:

- no first callback
- `captureState=never_started`
- zero frames
- repeated resets after start

then the next agent should *not* add more Bluetooth-specific heuristics.

The next action should be:

1. verify whether the engine backend still fails the required AirPods or Bose acceptance scenarios under the installed app
2. if yes, switch the production default to the `AVCapture` comparison backend that was added as part of this work
3. preserve the engine backend as a fallback/reference implementation only if it still provides useful debug value

In other words:

- do not add headset-name branching
- do not add sample-rate lookup tables
- do not keep inflating retry timing heuristics if the real capture primitive is wrong

## Short STEC conclusion

The thing that should not exist is a per-device Bluetooth frequency map.

The system should negotiate the Bluetooth route and native rate. DICTATR’s job is to either:

- observe the live route and graph correctly, or
- use a capture API that already provides native-format capture without making DICTATR reason about individual headsets.
