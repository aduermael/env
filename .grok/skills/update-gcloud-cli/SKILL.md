---
name: update-gcloud-cli
description: >
  Manual-only workflow for updating the Google Cloud CLI (gcloud) release pin
  in this repo. Use only when the user runs /update-gcloud-cli or asks to run
  the update-gcloud-cli skill; it checks for a clean Git worktree, runs
  ./scripts/update-gcloud-cli.sh, and opens a GitHub PR if dev.Dockerfile
  changes.
disable-model-invocation: true
argument-hint: "[latest|VERSION]"
metadata:
  short-description: "Update gcloud CLI pin and open a PR"
---

Read `.codex/skills/update-gcloud-cli/SKILL.md` and follow it exactly.

Treat `$ARGUMENTS` as the optional release argument for the bundled runner.
