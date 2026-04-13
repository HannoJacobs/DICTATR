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
