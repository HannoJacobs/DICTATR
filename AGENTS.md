# DICTATR Repo Rules

## Full Send

In this repo, a "full send" means the work is not done at code changes.

A full send includes all of the following:

1. Implement the requested change in the repo.
2. Update release metadata and docs that define the shipped state when needed.
3. Commit the change set to git.
4. Push the branch to GitHub.
5. Build the Release app artifact.
6. Package and upload the current `DICTATR.dmg` to the live GitHub release path.
7. Install the built app to `/Applications/DICTATR.app` on this Mac.
8. Launch the installed app.
9. Verify the live installed app from concrete evidence, not assumption.

Required verification evidence for a full send:

- the installed app log must show `/Applications/DICTATR.app`
- the installed app log must show the expected version/build
- the installed app log must show the requested behavior is live when that behavior can be exercised locally
- any failure in build, packaging, upload, install, launch, or verification must be surfaced immediately

Do not call something a full send if it only compiles, only ships a commit, or only uploads a DMG.

## Debug Research First

For sticky debugging issues, hardware-related problems, Swift code issues, macOS platform behavior, Bluetooth issues, or anything that smells like a system/framework edge case, spend significant time searching the web for relevant context before attempting to debug.

Expect to pull that external context into the working set first:

- search for current Apple documentation, forum threads, bug reports, release notes, and credible writeups
- look for version-specific Swift, AppKit, SwiftUI, macOS, CoreBluetooth, IOBluetooth, codesigning, sandboxing, and entitlement behavior
- prefer gathering multiple relevant sources before forming a debugging plan
- use that research to shape hypotheses, reproduction steps, instrumentation, and fixes instead of debugging from memory alone

Do not treat these issues like ordinary local code bugs when the surrounding platform behavior is likely part of the problem. Research first, then debug.
