# herdr-core machines for dev containers

The Herdr desktop app sees each dev container as a saved machine, next to the Herdr TUI profile that `dev up` already creates. The container runs a pinned `herdr-core` (`hc`). The app's local core connects to it over the same SSH alias, port, key, and host key the TUI uses. `dev down` and `dev up` bring the same machine back.

This is the follow-up to [Herdr machines for dev containers](herdr-dev-container-machines.md). Everything that plan built stays: the registry, the `devenv-<id>` alias, the Herdr keys, `sshd` as the main process, and the per-worktree volume. This plan adds one binary to the image, one symlink to the entrypoint, and one registration step to `dev up`.

## Client

The desktop app draws terminals; `herdr-core` runs them. The app's installer puts `herdr-core` and the `hc` symlink in `~/.local/bin` on the Mac when no `hc` exists, and the app's `Info.plist` adds that directory to its own `PATH`. The app lists the machines of the local core. `hc machine add` and the app's Settings → Machines write the same list, `~/.local/state/herdr-core/default/machines.json`.

The local core runs apart from the app since core 0.1.17. Quitting the app does not stop it, and it keeps the connection to each remote core.

The TUI and the desktop app do not share terminals. A pane opened in the TUI is not visible in the app, and an agent started in the app is not visible in the TUI. Both run in the same container, against the same files, home, and Docker proxy. That is the trade-off this plan accepts.

## What the local core treats as one machine

A saved machine is a name, an SSH target, an optional remote session, and the identity of the remote core. The target is the string given to `hc machine add`, handed to the system `ssh`, so a Host alias from `~/.ssh/config` works. `ssh` reads the config from the account's home as `getpwuid` reports it, not from `$HOME`.

The connection is a byte protocol over a non-PTY SSH command. The remote login must print nothing extra to stdout. The managed `sshd` config already sets `PrintMotd no`, `Banner none`, and `PermitUserRC no`, which is exactly that requirement. `hc` runs `ssh` without a terminal and cannot answer a host-key prompt. It never has to: the ready check in `dev up` runs `ssh devenv-<id> true` through the alias before any registration, and `accept-new` records the host key there. A recreated container presents the same key, so `hc` only ever sees a known host.

Every `hc` command that talks to machines starts the local core when it is not running, as a detached process that outlives the command. `dev up` therefore starts the Mac's core as a side effect of `hc machine ls`. The app would start it anyway.

The remote core has an identity, written to `core.json` in its state directory the first time it starts. The local core stores that identity with the machine. When a container comes back with a fresh state directory, the local core reports the machine as unreachable with the reason "a different core answers there" and does not connect. The Linux spike reproduced this by recreating a container whose state lived in the container's own filesystem. The state directory therefore has to persist per worktree, on the Herdr volume. The same rule that keeps the host key fixed keeps the core identity fixed.

When a container is recreated with its state intact, the local core reconnects on its own and starts the remote core again over SSH. The Linux spike killed the remote core and saw the local core start a new one within five seconds, and saw the remote core keep running while the local core was stopped. No supervisor loop is needed for `herdr-core`.

## Image

Pin `herdr-core` in `dev.Dockerfile` next to `herdr`:

```text
ARG HERDR_CORE_VERSION=0.1.17
ARG HERDR_CORE_SHA256_AMD64=<from the manifest>
ARG HERDR_CORE_SHA256_ARM64=<from the manifest>
```

The release manifest is `https://releases.herdr.dev/core/<version>/manifest.json`, and `https://releases.herdr.dev/core/latest.json` is the current one. It lists, per target, the archive URL and its SHA-256:

```text
linux-aarch64  https://releases.herdr.dev/core/0.1.17/herdr-core-linux-aarch64.tar.gz
linux-x86_64   https://releases.herdr.dev/core/0.1.17/herdr-core-linux-x86_64.tar.gz
```

The archive holds the static binary `herdr-core` plus `LICENSE` and `THIRD-PARTY-NOTICES`. The layer downloads it, extracts only the binary, checks the digest, installs it as `/usr/local/bin/herdr-core` mode `0755`, symlinks `/usr/local/bin/hc` to it, and asserts `hc --version` prints `hc <version>`. It goes right after the `herdr` layer so a bump rebuilds only the cheap tail of the image.

`scripts/update-herdr-core.sh` mirrors `scripts/update-herdr.sh`: with no argument it reads `latest.json`, with a version it reads that version's `manifest.json`, downloads both Linux archives, checks their digests against the manifest, rewrites the three `ARG` lines, and prints them. `scripts/test-herdr-core-pin.sh` and `scripts/test-update-herdr-core.sh` are copies of the existing tests with the names changed.

The Linux spike confirmed that `hc machine add` without `--install` uses a `hc` already on the remote `PATH` and copies nothing: the remote core ran as `/usr/local/bin/herdr-core serve`, and `~/.local/bin` was never created. When the remote has no `hc`, `machine add` copies the Mac's build to `~/.local/bin/herdr-core` plus the `hc` symlink. In this setup that directory is the shared `~/.devenv/home` bind mount, so a copied binary would persist across containers and shadow nothing, because `~/.local/bin` is not on the image `PATH`, but a second binary that the image does not pin is still the wrong outcome. `dev up` never passes `--install`.

## Entrypoint

After the Herdr symlinks and before `herdr server` starts, the entrypoint adds one more:

```text
${home_dir}/.local/state/herdr-core -> /var/lib/devenv/herdr/core-state
```

`/var/lib/devenv/herdr/core-state` is created on the volume, owned by the container user, mode `0700`. The rename-aside rule for a pre-existing real directory applies. The core's state, logs, screens, terminal records, and its `default.sock` all live under `<state>/default/`, so the socket is per worktree and the identity in `core.json` survives `dev down` and `dev up`. The Linux spike lists exactly these files there and nothing under `~/.local/share` or `~/.cache`.

`~/.config/herdr-core/` stays on the shared home. It holds only `config.toml` and templates, and those should be the same in every worktree. `XDG_STATE_HOME` and `XDG_CONFIG_HOME` are never set, for the reason the first plan gives. `XDG_RUNTIME_DIR` is unset in the container and `/run/user/<uid>` does not exist, so the core falls back to the state directory for its socket, which is the volume. That path is short enough for a Unix socket.

The local core on the Mac starts `herdr-core` over SSH on the first connection and again whenever it is gone. A core started that way inherits the `SetEnv` line of the managed `sshd` config. The Linux spike read `HOME`, `SHELL=/bin/bash`, `DOCKER_HOST`, `GIT_CONFIG_GLOBAL`, `CODEX_SQLITE_HOME`, and the image `PATH` from the remote core's environment, and its terminals ran `bash`. The core's working directory was the home.

Where a new terminal starts was the one open question for the entrypoint. `hc run --on <machine>` starts in the machine's home unless `--cwd` is given, and the core's own working directory is the default for terminals created through its API. The Mac spike settled it: a terminal opened in the app on a core started from `/workspace` starts in `/workspace`, and on a core the Mac started over SSH it starts in the home. So the entrypoint starts the core itself, from the pane directory, as the container user, with the same environment as `herdr server`, before `sshd`. `hc server start` detaches the core into its own session and returns at once, and when a core is already running it only reports it, so a core the Mac started first is left alone. The identity in `core.json` is the same either way, so a core started by the entrypoint and one started by the Mac are the same machine. A loop repeats the start every few seconds: every `hc` command auto-starts a missing core from its own directory, so without the loop an `hc server stop` in a pane would let the Mac's core bring it back from the home.

## Registration

After the Herdr TUI registration in `dev up`:

```text
hc machine ls --json
hc machine add devenv-<id> --name <id>
```

`machine ls --json` returns `machines`, each with `id`, `name`, `target`, `session`, `state`, `version`, `via`, `temporary`, and, when unreachable, `since_ms` and `why`. Skip `machine add` when an entry's `target` is the alias `devenv-<id>`. Match the target, not the name. A renamed machine is still the same machine.

When that entry has state `unreachable` and `why` starts with "a different core answers there", the core identity on the volume changed: the volume was removed, or the state directory was moved aside. The old entry can never connect again. `dev up` removes it with `hc machine rm <name>` and adds the alias again, and prints a notice saying so.

`dev up` looks for `hc` on `PATH` and then at `~/.local/bin/hc`, because the app's installer puts it there and a zsh `PATH` may not include that directory. When neither exists, `dev up` still succeeds and prints the install command and the exact `machine add` line, the same way it does for the TUI.

`machine add` in a terminal asks before copying `hc` to a remote that has none or one too old. The image has `hc`, so a prompt means the Mac core rejected the pinned version. Answer no, and bump the pin with `scripts/update-herdr-core.sh`. `dev up` prints that line before running `machine add`, as it does for `herdr`. A non-interactive `dev up` lets `machine add` fail, prints the error and the `machine add` line, and leaves the container up.

`hc machine update <name>` copies the Mac's `hc` to the remote and restarts the remote core. It is the emergency path when the app has updated its core past what the image pins and a rebuild is not possible right now. It leaves a second binary under `~/.devenv/home/.local/bin`, which the next image bump makes stale. The README says to prefer the pin.

`devenv down` does not touch the machine list. The machine goes unreachable and comes back on the next `dev up`. `devenv down --delete-data` removes the Herdr volume, so the core identity is gone with it. The notice that already tells people to run `herdr machine remove` also names `hc machine rm <id>`.

## Version check

The Mac core and the remote core have to be within whatever window `herdr-core` accepts. The docs only say a remote can be "too old to talk to". The app updates its core on its own schedule, so the pinned version will fall behind. Two things keep that from being a surprise:

- `dev up` runs `hc --version` inside the container with `docker exec` and compares it to the Mac's `hc --version`, printing a notice when they differ that names `scripts/update-herdr-core.sh`. The `version` in `hc machine ls --json` is the one the local core last observed, which is stale right after a rebuild, so it is not the source.
- The Mac spike records what `machine add` and the app do when the remote is one or two releases behind. If the window is narrow, the plan for the pin changes from "bump when needed" to "bump with every app update", and the README says so.

## Spike

The Linux half ran against throwaway containers from the current image, with `hc 0.1.17` on both sides, and is recorded above. The Mac half, against the desktop app and the installed `hc`, has to confirm:

- `hc machine add devenv-<id> --name <id>` from a Mac terminal saves the machine, with the alias resolved through the managed include in `~/.ssh/config`, and the app shows it without a restart. Adding the same alias from Settings → Machines lands in the same list.
- A recreated container on the same alias, port, and host key, with its volume intact, reconnects as the same machine with the same core identity. A container whose volume was deleted is reported as a different core, and `dev up` replaces the entry.
- Where a new terminal opened in the app starts on the remote machine: the home, the core's working directory, or a folder the app remembers. This decides whether the entrypoint starts the core from the pane directory. Result: the core's working directory, so the entrypoint starts it from the pane directory.
- Terminals opened in the app have `DOCKER_HOST`, `GIT_CONFIG_GLOBAL`, `CODEX_SQLITE_HOME`, and the image `PATH`, and `docker ps` works in one of them.
- An agent started in the app keeps running after the app quits, after the Mac sleeps, and after `dev down` and `dev up` it is gone, which is the same rule as the TUI.
- What the Mac core does when the remote is one release behind and two releases behind, and whether `machine add` in a terminal offers to copy the Mac build in either case.
- The published port is not reachable from the LAN. This repeats the TUI check because the app may keep a connection open that the TUI did not.

If the app cannot use a core that was started over SSH by a different `hc` build, or if it requires the remote core to be installed by its own installer, stop and revise this plan.

## CLI and image changes

Image, in `dev.Dockerfile`:

- Add the `herdr-core` layer with the three `ARG`s, the digest check, the `hc` symlink, and the version assertion.
- Extend `dev-entrypoint` with the `~/.local/state/herdr-core` symlink and the `core-state` directory on the volume, and start the core from the pane directory, since the Mac spike showed the app honors it.

Scripts:

- Add `scripts/update-herdr-core.sh`, `scripts/test-herdr-core-pin.sh`, and `scripts/test-update-herdr-core.sh`.

CLI, in `cmd/devenv/herdr.go`:

- Add `hc` lookup on `PATH` and `~/.local/bin`.
- Add the `machine ls --json` parser and the "different core" detection as pure functions.
- Add `hc` registration to `dev up` after the TUI registration, with the replace path for a changed core identity and the version notice.
- Extend the `--delete-data` notice.

Docs, in `README.md`:

- The container is also a desktop-app machine. The TUI and the app do not share terminals.
- `~/.devenv/home/.local/state/herdr-core` is a symlink onto the per-worktree volume. `~/.config/herdr-core` stays shared.
- The pin, the update script, and the version notice. `hc machine update` is the emergency path and why it is not the default.
- The Herdr section of "Update ... in the dev image" gains a `herdr-core` entry.

## Tests

Unit tests in `cmd/devenv/main_test.go`, without Docker:

- `hc machine ls --json` parsing: an entry with the alias target is registered regardless of its name; an entry with a different target and the same name is not.
- An unreachable entry whose `why` names a different core is flagged for replacement; an unreachable entry with any other reason is left alone.
- The `machine add` argument list is `machine add devenv-<id> --name <id>` with no `--install`.
- `hc` lookup prefers `PATH` and falls back to `~/.local/bin/hc`.
- The version notice fires when the remote and local versions differ and stays quiet when they match.

The pin tests check the three `ARG` lines against the manifest the same way the `herdr` tests do.

## Out of scope

- Replacing the TUI registration with the app, or bridging terminals between the two.
- A per-worktree `~/.config/herdr-core`.
- Installing `hc` on the Mac. The app's installer does that.
- Custom connections through `--via`. The alias is enough, and the Linux spike used `--via` only because that container's `~/.ssh/config` is not the one the tests could edit.
