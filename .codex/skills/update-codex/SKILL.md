---
name: update-codex
description: Manual-only workflow for updating the Codex release pin in this repo. Use only when the user explicitly invokes $update-codex or asks to run the update-codex skill; it checks for a clean Git worktree, runs ./scripts/update-codex.sh, and opens a GitHub PR if dev.Dockerfile changes.
---

# Update Codex

Use this skill only when explicitly invoked. Its purpose is to run the repo's Codex updater and open a PR for any resulting `dev.Dockerfile` version/checksum change.

## Workflow

Run the bundled runner from anywhere inside the target Git repository:

```bash
./.codex/skills/update-codex/scripts/update-codex-pr.sh
```

Pass one optional release argument only when the user requested a specific Codex release:

```bash
./.codex/skills/update-codex/scripts/update-codex-pr.sh rust-v0.142.2
```

The runner enforces the required behavior:

- Fail immediately if the current worktree has uncommitted, staged, or untracked files.
- Fetch `origin/main`.
- Run `./scripts/update-codex.sh` in a temporary worktree based on `origin/main`.
- Stop without a commit or PR when `dev.Dockerfile` is unchanged.
- Fail if the updater changes anything other than `dev.Dockerfile`.
- Create a fresh branch from `origin/main`, commit `dev.Dockerfile`, push it to `origin`, and open a GitHub PR with `gh pr create`.

## Reporting

After the runner exits, report:

- Dirty-tree failure details, if it stopped before running the updater.
- "No update detected" when no Dockerfile change was produced.
- Branch name, commit SHA, and PR URL when a PR was opened.

Do not hand-roll the GitHub PR workflow unless the bundled runner is missing or broken; if that happens, repair the runner first when feasible.
