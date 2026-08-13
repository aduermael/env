---
name: update-cursor
description: >
  Manual-only workflow for updating the Cursor CLI release pin in this repo.
  Use only when the user runs /update-cursor or asks to run the update-cursor
  skill; it checks for a clean Git worktree, runs ./scripts/update-cursor.sh,
  and opens a GitHub PR if dev.Dockerfile changes.
disable-model-invocation: true
argument-hint: "[latest|VERSION]"
metadata:
  short-description: "Update Cursor CLI pin and open a PR"
---

Read `.codex/skills/update-cursor/SKILL.md` and follow it exactly.

Treat `$ARGUMENTS` as the optional release argument for the bundled runner.
