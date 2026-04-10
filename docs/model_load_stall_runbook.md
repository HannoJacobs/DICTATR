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

- DICTATR now logs both `effectiveVariant` and `whisperKitDefault` during model selection.
- On the affected M1 Mac class, DICTATR overrides WhisperKit's `openai_whisper-large-v3-v20240930_626MB` default and uses `openai_whisper-small.en` instead.
- Treat any future reappearance of the old large-v3 default on this machine as a model-selection regression first, not just a cache incident.

## Fast Triage

1. Inspect the latest diagnostics log:

```bash
tail -n 80 ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

2. Confirm whether the failure is a warm-cache compile stall:

```bash
rg -n "Model variant selected|CoreML load started|Model load still running|Model load completed|compiledCache" ~/Library/Application\ Support/DICTATR/Logs/latest.log
```

Treat it as a compiled-cache incident when:
- The logged `effectiveVariant` matches the current policy for this machine.
- The model folder is already local.
- `compiledCache exists=yes`.
- The app stays in `Compiling on-device model...` for much longer than the normal warm path.

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
- The next launch should log `Model variant selected ...`.
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
