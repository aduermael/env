---
name: update-codex
description: >
  Manual-only workflow for updating the Codex release pin in this repo. Use
  only when the user runs /update-codex or asks to run the update-codex skill;
  it checks for a clean Git worktree, runs ./scripts/update-codex.sh, and
  opens a GitHub PR if dev.Dockerfile changes.
disable-model-invocation: true
argument-hint: "[latest|VERSION|TAG]"
metadata:
  short-description: "Update Codex pin and open a PR"
---

Read `.codex/skills/update-codex/SKILL.md` and follow it exactly.

Treat `$ARGUMENTS` as the optional release argument for the bundled runner.
