---
name: update-software
description: Manual-only workflow for updating the Grok Build, Codex, Cursor CLI, or Google Cloud CLI (gcloud) release pin in this repo. Use only when the user explicitly invokes $update-software or asks to run the update-software skill; it checks for a clean Git worktree, runs the matching ./scripts/update-*.sh, and opens a GitHub PR if dev.Dockerfile changes.
---

# Update software pins

Use this skill only when explicitly invoked. Its purpose is to run one of this repo's pin updaters and open a PR for any resulting `dev.Dockerfile` version/checksum change.

Supported `PACKAGE` values:

- `grok` — `./scripts/update-grok.sh` (without a release argument, tracks the package's NPM `alpha` dist-tag)
- `codex` — `./scripts/update-codex.sh`
- `cursor` — `./scripts/update-cursor.sh`
- `gcloud-cli` — `./scripts/update-gcloud-cli.sh`

## Workflow

Run the bundled runner from anywhere inside the target Git repository. Pass the package the user asked to update (once per package):

```bash
./.codex/skills/update-software/scripts/update-software-pr.sh grok
```

Pass one optional release argument only when the user requested a specific version:

```bash
./.codex/skills/update-software/scripts/update-software-pr.sh grok 0.2.82
./.codex/skills/update-software/scripts/update-software-pr.sh codex rust-v0.142.2
./.codex/skills/update-software/scripts/update-software-pr.sh cursor 2026.07.16-899851b
./.codex/skills/update-software/scripts/update-software-pr.sh gcloud-cli 581.0.0
```

The runner enforces the required behavior:

- Fail immediately if the current worktree has uncommitted, staged, or untracked files.
- Fetch `origin/main`.
- Run that package's `./scripts/update-*.sh` in a temporary worktree based on `origin/main`.
- Stop without a commit or PR when `dev.Dockerfile` is unchanged.
- Fail if the updater changes anything other than `dev.Dockerfile`.
- Create a fresh branch from `origin/main`, commit `dev.Dockerfile`, push it to `origin`, and open a GitHub PR with `gh pr create`.

## Reporting

After the runner exits, report:

- Dirty-tree failure details, if it stopped before running the updater.
- "No update detected" when no Dockerfile change was produced.
- Branch name, commit SHA, and PR URL when a PR was opened.

Do not hand-roll the GitHub PR workflow unless the bundled runner is missing or broken; if that happens, repair the runner first when feasible.
