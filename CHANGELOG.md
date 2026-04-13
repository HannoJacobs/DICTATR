# Changelog

Changelog policy:
- Current known-status caveat: the installed-build dictation regression is fixed and verified, but the earlier Bluetooth-specific route/recovery issue is still not conclusively fixed. Until a focused Bluetooth retest proves otherwise, release notes should not claim that Bluetooth dictation reliability is resolved.
- Every shipped version entry must be written as a detailed operator-facing record, not a terse marketing summary.
- The current release entry is required to be very verbose: the release pipeline now fails if the section for the bundled app version has fewer than 8 bullet points or fewer than 1200 characters.
- Each new entry should explain the user-visible problem, the technical root cause, the code-path changes, the release/signing or operational changes when relevant, and the concrete verification outcome.

## 1.28
- Fixed the installed-build dictation regression introduced by the archive-based release flow on April 13, 2026, where `/Applications/DICTATR.app` could still start, show the normal menu state, and record a WAV file full of frames, but the actual captured waveform was silent because the installed ad-hoc build had lost the microphone entitlement during packaging.
- Corrected the release signing pipeline so ad-hoc builds now embed `com.apple.security.device.audio-input=true` and no longer enable hardened runtime accidentally, while Developer ID builds still keep the hardened-runtime requirement. This directly fixes the TCC failure mode where macOS refused to prompt for microphone access because the signed app did not qualify for `kTCCServiceMicrophone`.
- Added a checked-in app entitlements file and made release verification print the embedded entitlements for both the archived bundle and the installed `/Applications/DICTATR.app`. The release scripts now fail immediately if the shipped app is missing the microphone entitlement or if ad-hoc mode accidentally carries a runtime flag again.
- Tightened release verification so the packaged build is no longer treated as correct just because `codesign --verify` passes. DICTATR now validates bundle identity, signing mode, hardened-runtime expectations, embedded microphone entitlement state, designated requirement shape, `spctl` expectations, and live launch-log evidence from the installed app.
- Centralized microphone permission handling into one shared code path used by launch, onboarding, the menu-bar UI, and the recording start path. This removes the previous behavior where onboarding state could claim setup was complete even though a newly installed signed app still needed a fresh microphone grant.
- Changed the recording gate so DICTATR will not begin capture when microphone access is denied or restricted, and it now requests access up front when the state is `notDetermined`. The app reports an explicit microphone-permission problem instead of falling through into a recording session that looks successful in timing terms but produces silent audio and empty dictation.
- Added visible microphone status to the menu, alongside the existing Accessibility row, so a broken installed build is diagnosable from the app itself. The menu and onboarding now both route the user to the correct microphone permission flow or to System Settings when the app needs repair.
- Preserved raw Whisper placeholder-token logging for forensics, but changed the user-facing behavior so placeholder-only output and long silent captures are treated as microphone/capture failures instead of ordinary “No speech detected.” This keeps the diagnostic evidence while removing the misleading symptom where the dictated text simply appears to vanish.
- Verified the shipped fix on the live installed app, not just in the development build. The installed `1.28` app launched from `/Applications/DICTATR.app`, requested microphone permission successfully, transitioned to `microphoneStatus=authorized`, recorded non-zero waveform data, produced real transcription output, and pasted that transcription back into the active app.
- Verified the TCC behavior change directly in system logs. The old `tccd` failure stating that DICTATR was missing `com.apple.security.device.audio-input` is gone for the new installed build, and macOS now emits the expected microphone prompt and grant path instead of policy-denied silent capture.

## 1.27
- Promoted long blank dictations to explicit errors so any recording that runs for at least 5 seconds and still normalizes to empty text is treated as a real failure in the diagnostics log.
- Added recording duration to the app-state transcription return/completion logs, along with the full normalized dictated text payload, so blank-output incidents can be correlated directly with how long the user was speaking.

## 1.26
- Added aggressive end-to-end diagnostics across DICTATR so future random failures leave a much more complete forensic trail in `latest.log`.
- App state changes now log old and new values together with a full runtime snapshot, including model state, retry state, frontmost app, and the active audio route.
- Audio diagnostics now explicitly record built-in-versus-Bluetooth microphone selection, default input/output transport state, full device inventories, and richer recorder/config-change/reset context.
- Transcription diagnostics now log source file metadata, decode options, per-segment text, raw generated text, and normalized output text before paste/history handling.
- Pasteboard, hotkey, HTTP server, and database operations now emit verbose request/response and state logs so failures can be correlated across the whole dictation pipeline.

## 1.23
- Replaced the old hand-built DMG wrapper with an archive-based release path that packages the real macOS app bundle instead of reconstructing `Contents/` around a raw binary.
- Added centralized release signing config in `release.env`, fail-fast signing checks, designated-requirement validation, and configurable `spctl` verification so DICTATR ships with a stable code identity instead of a per-build `cdhash`.
- Added `install-release.sh` to install the archived app to `/Applications/DICTATR.app`, verify the installed signature and launch log, and surface missing Accessibility trust by resetting DICTATR's TCC entry and opening the Accessibility pane.
- Fixed the local release installer so it terminates any already-running DICTATR process before reinstalling, ensuring full-send verification checks a fresh launch of the installed app instead of reactivating an older session.
- Fixed the launch-log verification matcher in `install-release.sh` so it matches the actual runtime diagnostic field order emitted by DICTATR.
- Fixed fresh-launch detection in `install-release.sh` so it verifies against the new `latest.log` target created for the relaunched app, rather than comparing launch counts across different log files.
- Added an explicit `adhoc` release mode for local non-Developer-ID builds. That mode still verifies the shipped app and launch log, but it now explicitly forces the Accessibility re-enable flow because trust persistence is impossible without stable signing.
- Launch diagnostics now record `accessibilityTrusted=yes|no`, so full-send verification can prove whether the installed app retained Accessibility permission after an upgrade.

## 1.25
- Filtered placeholder Whisper tokens such as `[BLANK_AUDIO]` out of user-visible transcription results so DICTATR treats them as empty transcription instead of pasting them.
- Added transcription diagnostics that log both the raw Whisper output text and the normalized text used by DICTATR, so silence and post-processing failures can be debugged from `latest.log`.

## 1.24
- Documented the product rule that DICTATR must use the active headphone microphone when headphones are the selected route, and that built-in mic fallback is not an allowed workaround for Bluetooth regressions.

## 1.22
- Removed the built-in-mic fallback path so DICTATR now stays on the active system route instead of switching away from Bluetooth input during recovery.
- Changed recording retries to reconnect on the current route, which keeps Bluetooth microphone and Bluetooth headphone output paired through HFP renegotiation instead of forcing a mixed-device route.
- Documented the post-`1.21` AirPods follow-up investigation in [`docs/bluetooth_audio_followup_handoff_2026-04-10.md`](/Users/hannojacobs/Documents/Code/DICTATR/docs/bluetooth_audio_followup_handoff_2026-04-10.md), including the shipped change, the failed AirPods retest, and the diagnosis that led to the `1.22` route-policy fix.

## 1.21
- Added a `Hard Reset Audio` menu action that force-resets DICTATR's own recorder state and terminates the owning Chromium/Electron app process when one of its audio utility helpers is contending for the microphone route.
- Hard audio reset outcomes are now logged explicitly, including killed owner-process PIDs, skipped processes, and process-enumeration failures, so future Bluetooth or route-churn incidents leave a concrete audit trail.
- Recorded April 10 Bluetooth investigation evidence showing that both AirPods 3 and Bose QC45 did work in DICTATR before the current regression, so the active issue should be treated as a new breakage rather than a permanent Bluetooth limitation.
- Replaced the risky in-place tap reinstall during Bluetooth route reconfiguration with a clean recorder reset plus reconnect, avoiding the observed `format.sampleRate == inputHWFormat.sampleRate` AVAudioEngine assertion during route churn.

## 1.20
- Stopped trusting WhisperKit's heavy `openai_whisper-large-v3-v20240930_626MB` default on the affected M1 Mac class and now prefer `openai_whisper-small.en` there for startup reliability.
- Added explicit diagnostics for the effective model variant, the WhisperKit default it replaced, and the selection reason so future startup incidents can distinguish a policy choice from a package default.
- Removed the fake `large-v3-turbo` settings placeholder and replaced it with truthful model-policy status in the Settings panel.
- Fixed the menu error action so `Retry Model Load` only appears when a real model retry can happen, instead of offering a misleading retry while a compile is already in flight.

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
