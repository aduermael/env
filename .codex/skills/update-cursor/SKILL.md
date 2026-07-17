---
name: update-cursor
description: Manual-only workflow for updating the Cursor CLI release pin in this repo. Use only when the user explicitly invokes $update-cursor or asks to run the update-cursor skill; it checks for a clean Git worktree, runs ./scripts/update-cursor.sh, and opens a GitHub PR if dev.Dockerfile changes.
---

# Update Cursor CLI

Use this skill only when explicitly invoked. Its purpose is to run the repo's Cursor CLI updater and open a PR for any resulting `dev.Dockerfile` version/checksum change.

## Workflow

Run the bundled runner from anywhere inside the target Git repository:

```bash
./.codex/skills/update-cursor/scripts/update-cursor-pr.sh
```

Pass one optional release argument only when the user requested a specific Cursor CLI release:

```bash
./.codex/skills/update-cursor/scripts/update-cursor-pr.sh 2026.07.16-899851b
```

The runner enforces the required behavior:

- Fail immediately if the current worktree has uncommitted, staged, or untracked files.
- Fetch `origin/main`.
- Run `./scripts/update-cursor.sh` in a temporary worktree based on `origin/main`.
- Stop without a commit or PR when `dev.Dockerfile` is unchanged.
- Fail if the updater changes anything other than `dev.Dockerfile`.
- Create a fresh branch from `origin/main`, commit `dev.Dockerfile`, push it to `origin`, and open a GitHub PR with `gh pr create`.

## Reporting

After the runner exits, report:

- Dirty-tree failure details, if it stopped before running the updater.
- "No update detected" when no Dockerfile change was produced.
- Branch name, commit SHA, and PR URL when a PR was opened.

Do not hand-roll the GitHub PR workflow unless the bundled runner is missing or broken; if that happens, repair the runner first when feasible.
