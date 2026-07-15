# Model Load Stall Runbook

## What Failed On 2026-04-10

Observed behavior:
- `DICTATR` launched normally.
- WhisperKit's default M1 model was `openai_whisper-large-v3-v20240930_626MB`.
- The local WhisperKit model folder was found immediately.
- `TranscriptionEngine` entered `Compiling on-device model...`.
- Warm-cache heartbeats continued for multiple minutes and never converged into the normal 1-3 second warm start seen in earlier logs.

The strongest evidence was:
- Launch session `7df24c11` on 2026-04-10 stayed in `Compiling on-device model...` while `compiledCache exists=yes`.
- Live process samples showed the work inside Apple's CoreML / AppleNeuralEngine compilation stack, not in app UI code.
- Clearing `~/Library/Caches/com.hannojacobs.DICTATR/com.apple.e5rt.e5bundlecache` changed the behavior from an obviously bad warm launch into a cold recompile, which confirms the incident is tied to the compiled ANE cache path.
- A later cold compile of that same variant still took just over 6 minutes, which means the package default itself was operationally too slow for DICTATR on this Mac even when recovery worked.

## Current Policy

- DICTATR defaults to `openai_whisper-small.en` when `selectedWhisperModelVariant` is absent or invalid.
- Settings can explicitly select `openai_whisper-large-v3-v20240930_626MB`. An intentional Large V3 selection is not a regression, but it can legitimately trigger a multi-minute compile even when its model files are already cached.
- Diagnostics distinguish `selected`, `target`, and `active`. Only `active` names the pipeline that completed loading successfully; during loading or failure it may be `nil` even though the selected preference remains Large V3.
- WhisperKit's recommended model is still logged for context, but it no longer overrides the persisted user choice.
- Treat Large V3 as a model-selection regression only when the stored selection resolves to Small while the logged target or active variant is Large.

## Fast Triage

1. Inspect the latest diagnostics log:

```bash
tail -n 80 ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

2. Confirm whether the failure is a warm-cache compile stall:

```bash
rg -n "selected=|target=|active=|CoreML load started|Model load still running|Model load completed|Model load failed|compiledCache" ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

Treat it as a compiled-cache incident when:
- The logged target matches the stored selection shown in Settings/defaults.
- The model folder is already local.
- `compiledCache exists=yes`.
- The app stays in `Compiling on-device model...` for much longer than the normal warm path.

Before resetting caches, confirm that no model switch is currently running. DICTATR switches with one pipeline only: it unloads the active model before loading the selected target, and the picker is disabled while recording, transcribing, serving an HTTP transcription, loading, or switching.

3. If needed, sample the live process:

```bash
sample "$(pgrep -x DICTATR | head -1)" 3 1
```

The April 10 incident sampled inside Apple's `MLE5Engine` / `AppleNeuralEngine` compile path.

## Immediate Operator Recovery

```bash
pkill -x DICTATR
rm -rf ~/Library/Caches/com.hannojacobs.DICTATR/com.apple.e5rt.e5bundlecache
open -a /Applications/DICTATR.app
tail -f ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

What to expect:
- The next launch should log the selected/target variant and later the exact active variant after a successful load.
- The next launch should log `compiledCache=missing` before compile begins.
- The app will do a cold ANE compile again, which may still take several minutes.
- A healthy warm cache should make later launches fast again.

If the cold compile again exceeds the worst known prior compile time in the logs, capture:
- The latest `latest.log`
- A fresh `sample`
- The current macOS build from the launch log

## Automatic Recovery Added In Code

The app now persists in-flight model-load state at:

```bash
~/Library/Application\ Support/DICTATR/Diagnostics/model-load-recovery.json
```

Behavior:
- The file is written while model load is in progress.
- If a launch dies during compile, the next launch clears `com.apple.e5rt.e5bundlecache` before loading the model again, even when the interrupted launch started from a missing cache and left behind a partial compile.
- Long compiles now log the exact manual reset command so the operator does not have to rediscover it during an incident.
- The menu now stays available while the model loads in the background, so startup no longer appears dead just because the ANE compile is still running.

## What This Does Not Claim

- This does not prove the root cause is entirely inside DICTATR.
- The live samples point strongly at Apple's CoreML / ANE compile path.
- DICTATR's responsibility is to detect the incident, preserve evidence, and recover predictably on the next launch.
