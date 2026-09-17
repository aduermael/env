---
name: update-software
description: >
  Manual-only workflow for updating the Grok Build, Codex, Cursor CLI,
  Google Cloud CLI (gcloud), kubectl, or gke-gcloud-auth-plugin release
  pin in this repo. Use only when the user runs /update-software or asks
  to run the update-software skill; it checks for a clean Git worktree,
  runs the matching ./scripts/update-*.sh, and opens a GitHub PR if
  dev.Dockerfile changes.
disable-model-invocation: true
argument-hint: "PACKAGE [latest|VERSION|TAG]"
metadata:
  short-description: "Update a software pin and open a PR"
---

Read `.codex/skills/update-software/SKILL.md` and follow it exactly.

Treat `$ARGUMENTS` as the PACKAGE and optional release argument for the bundled runner.
