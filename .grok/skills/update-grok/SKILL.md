---
name: update-grok
description: >
  Manual-only workflow for updating the Grok Build CLI pin in this repo. Use
  only when the user runs /update-grok or asks to run the update-grok skill;
  it checks for a clean Git worktree, runs ./scripts/update-grok.sh, and
  opens a GitHub PR if dev.Dockerfile changes.
disable-model-invocation: true
argument-hint: "[latest|VERSION]"
metadata:
  short-description: "Update Grok Build pin and open a PR"
---

Read `.codex/skills/update-grok/SKILL.md` and follow it exactly.

Treat `$ARGUMENTS` as the optional release argument for the bundled runner.
