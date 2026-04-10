# Changelog

## 1.19
- Added persistent model-load recovery tracking under `~/Library/Application Support/DICTATR/Diagnostics/model-load-recovery.json` so an interrupted compile can be detected on the next launch instead of looking like an unexplained repeat failure.
- Any interrupted model compile now clears the compiled ANE cache on the next launch, including the case where the previous launch was the first cold compile after a cache reset.
- Slow model compiles now log an explicit compiled-cache warning with the exact manual remediation command and note that the next launch will clear the compiled cache automatically if this launch is force-quit.
- DICTATR no longer blocks the menu behind the startup model screen while WhisperKit compiles in the background, so the app can still open and show status during a long compile.
- Documented the April 10 model compile stall recovery procedure in the README and a dedicated runbook so future incidents have a concrete operator path instead of ad hoc diagnosis.

## 1.18
- Removed recursive directory size scans from the startup diagnostics hot path after they were shown to block model loading on the main thread. Startup logs now record cache/model paths and existence without introducing a new stall.

## 1.17
- Short-circuited normal startup to the local cached WhisperKit model folder when it is already present, so relaunches no longer depend on a remote HuggingFace lookup just to rediscover files that are already on disk.

## 1.16
- Added direct `TranscriptionEngine` diagnostics so model startup now records the selected WhisperKit variant, resolved model folder, compiled-cache snapshot, download progress milestones, per-phase timings, and 15-second heartbeats while a load is still in flight.
- Replaced the misleading fully-filled startup bar during CoreML/ANE compilation with an indeterminate loader and an explicit explanation that the first load after an install, update, or cache reset can take several minutes.
- Promoted slow model loads to warnings in the diagnostics log so future startup stalls are immediately distinguishable from a real deadlock.

## 1.15
- Added persistent per-launch diagnostics logs under `~/Library/Application Support/DICTATR/Logs/` so Bluetooth and audio failures can be investigated even when the unified log is incomplete.
- Added launch/reopen lifecycle logging with app version, build number, OS/build, hardware model, route snapshot, and full device inventory.
- Added verbose recording diagnostics around start, retries, watchdog failures, config changes, force resets, built-in mic fallback, and stop/transcription transitions.
- Moved app bundle metadata into [`Sources/DICTATR/Info.plist`](/Users/hannojacobs/Documents/Code/DICTATR/Sources/DICTATR/Info.plist) so runtime version reporting and packaging share one source of truth.
