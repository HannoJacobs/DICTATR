# DICTATR Repo Rules

## Full Send

In this repo, a "full send" means full send. The work is not done at code changes, not done at a local build, and not done at "the release should pick it up."

A full send includes all of the following:

1. Implement the requested change in the repo.
2. Update release metadata and docs that define the shipped state when needed.
3. Commit the entire required change set to git. Do not leave required release, docs, packaging, or website-triggering changes uncommitted.
4. Push the full change set to GitHub.
5. Build the Release app artifact.
6. Package the current `DICTATR.dmg`.
7. Upload the current `DICTATR.dmg` to the live GitHub release path.
8. Make sure the GitHub-hosted release state is live and that anything expected to update from GitHub is actually triggered for release, including the website/download path when applicable.
9. Update the local DMG/build artifacts so this Mac is using the current shipped build, not a stale previous package.
10. Install the built app to `/Applications/DICTATR.app` on this Mac.
11. Launch the installed app.
12. Verify the live installed app from concrete evidence, not assumption.

Required verification evidence for a full send:

- the installed app log must show `/Applications/DICTATR.app`
- the installed app log must show the expected version/build
- the installed app log must show the requested behavior is live when that behavior can be exercised locally
- the GitHub release path used by the website/download flow must point at the newly shipped DMG when that path is part of the release flow
- any failure in build, packaging, upload, install, launch, or verification must be surfaced immediately

Accessibility trust and microphone permission are special cases for local full-send verification on this Mac:

- If the newly installed app launches from `/Applications/DICTATR.app` with the expected version/build, but the log still shows `accessibilityTrusted=no` or `microphoneStatus=notDetermined|denied`, treat that as a required user handoff step and reminder, not as a reason to discard the rest of the full-send work or crash out.
- Surface it clearly and briefly as: “local permission step still required: re-enable Accessibility and/or grant Microphone to `/Applications/DICTATR.app`, then continue verification.”
- After the user grants the permission, continue verification from the same installed app flow and use the installed app log as evidence of the permission transition plus the requested behavior.
- Do not keep re-framing this permission handoff as a packaging or build failure once install and launch verification have already succeeded.

Do not call something a full send if it only compiles, only ships a commit, only pushes code, only uploads a DMG, or only assumes GitHub/Pages/release propagation happened without verifying the live state.

## Debug Research First

For sticky debugging issues, hardware-related problems, Swift code issues, macOS platform behavior, Bluetooth issues, or anything that smells like a system/framework edge case, spend significant time searching the web for relevant context before attempting to debug.

Expect to pull that external context into the working set first:

- search for current Apple documentation, forum threads, bug reports, release notes, and credible writeups
- look for version-specific Swift, AppKit, SwiftUI, macOS, CoreBluetooth, IOBluetooth, codesigning, sandboxing, and entitlement behavior
- prefer gathering multiple relevant sources before forming a debugging plan
- use that research to shape hypotheses, reproduction steps, instrumentation, and fixes instead of debugging from memory alone

Do not treat these issues like ordinary local code bugs when the surrounding platform behavior is likely part of the problem. Research first, then debug.
