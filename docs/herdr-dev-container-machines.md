# Herdr machines for dev containers

A macOS Herdr TUI connects to dev-env containers as saved SSH machines. Each git worktree has at most one dev container. The container is the machine: it stays up when the Herdr client disconnects. `dev down` stops that worktree. The next `dev up` brings the same Herdr machine back.

This is the implementation plan. It describes behavior to build. It does not change the image or the CLI by itself.

## Client

The Mac client is the Herdr TUI (`herdr`). The image already installs that binary, pinned in `dev.Dockerfile` as `HERDR_VERSION` (currently 0.9.5).

The Herdr desktop app is a different program. It talks to `herdr-core` (`hc`). The TUI server and `herdr-core` do not share agents. This plan does not install `hc` and does not register machines with the desktop app.

Herdr is the only terminal client. `dev` does not open a shell and does not run a one-shot command. Agents and shells are Herdr panes on that machine.

## What Herdr treats as one machine

A saved Herdr machine is an SSH target plus one remote session. The profile stores an opaque id, a label, the SSH target, the session name, and an enabled flag. Herdr does not store a Docker id, and it does not discover containers.

The same machine across container recreates means all of these stay fixed:

- SSH host alias
- `HostName` and `Port` behind that alias
- SSH user
- host key presented by `sshd`
- remote session name (`default`)

Herdr already reconnects when that SSH target goes away and comes back. The sidebar row stays. While the container is gone, the row is dimmed cached state and input is disabled. When SSH works again, the client reconnects. `devenv` must not remove or re-add the Herdr profile when the container is recreated.

A new alias, a new port, or a new host key is a different machine, or a host-key failure. Herdr reports a changed host key as attention and waits for a person. It does not accept the new key by itself.

Closing the Mac client leaves the remote server running. Stopping or removing the container stops the server and every process in it. Herdr can restore the saved layout on the next server start when its state directory survives. The original processes do not survive. Supported agent sessions resume as new processes. That is the same rule Herdr uses for a machine reboot.

## Worktree identity

One dev container per git worktree. A second container for that worktree is refused while the first exists.

The identity key is the worktree's absolute git directory:

- main checkout: `<repo>/.git`
- linked worktree: `<repo>/.git/worktrees/<gitdir-name>`, where `<gitdir-name>` is whatever git chose and can differ from the checkout's `<name>` (see below)

Linked worktrees exist only at `<repo>/worktrees/<name>`. `dev up` from any other linked-worktree path fails and names that expected directory.

Resolve it on the Mac before the container starts, by walking parent directories. Do not require a `git` binary on the Mac.

Resolve symlinks first. Run `filepath.EvalSymlinks` on the current directory before the walk, and on the git directory and repository root after it. On macOS `/tmp` and `/var` are symlinks into `/private`, and people symlink project directories. Without this, two invocations through different spellings of one path mint two ids and two containers for one worktree. The resolved paths are what the registry key, the container labels, and the bind mounts use.

- A `.git` directory means this is the main worktree. Its git directory is that path. The repository root is its parent.
- A `.git` file containing `gitdir: <path>` is a linked worktree. Resolve a relative `<path>` against the directory that contains the `.git` file. `<git-dir>/commondir`, usually `../..`, resolves against the git directory to the main `.git`. The checkout path must be `<repo>/worktrees/<name>`, where `<repo>` is the parent of that main `.git`. `<name>` is the final component of the checkout path, the directory that holds the `.git` file. Do not derive it from the git directory: git names `.git/worktrees/<x>` after the checkout basename but appends a number on collision, so `worktrees/feature` can own `.git/worktrees/feature1`. The only check on the git directory is that it lives under the main `.git/worktrees/`.
- A `.git` file whose gitdir is under `.git/modules/` is a submodule. Keep walking to the superproject checkout and use that worktree's machine. Do not create a container for the submodule.

`dev up` from a subdirectory uses that worktree. The container bind-mounts the repository root (the parent of the main `.git`) at `/workspace` and, when that path differs, at the same absolute path it has on the Mac. One mount covers `.git`, the main files, and every `worktrees/<name>` checkout. A relative `gitdir:` such as `../../.git/worktrees/<name>` resolves inside `/workspace`. An absolute `gitdir:` written by the Mac's git resolves through the host-path mount.

Herdr panes start at the worktree checkout, not at `$HOME`:

- main checkout: `/workspace`
- linked worktree: `/workspace/worktrees/<name>`

`dev up` outside a worktree fails with an error. It does not start an anonymous container.

### Machine id

Mint the id once, the first time a worktree gets a dev container. Store it in the worktree record. Later runs reuse it.

```text
<repo-slug>-<worktree-slug>-<6 random chars>
```

- `repo-slug` is the directory name of the main checkout (the parent of the common `.git`), sanitized. When `commondir` is absent, use the directory that contains the `.git` that was found.
- `worktree-slug` is `root` for the main worktree. For a linked worktree it is `<name>` from the checkout path `<repo>/worktrees/<name>`. Sanitize that component.
- The suffix is 6 characters from `crypto/rand`, alphabet `a-z0-9`. Generate again if that full id is already in the registry.

Sanitize a slug to lowercase `[a-z0-9-]`, collapse repeated dashes, and trim dashes. Cap each slug at 24 characters so the Docker name stays within 63 characters. An empty slug becomes `repo` or `wt`.

Examples: `env-root-a1b2c3`, `env-feature-auth-c4d5e6`.

The Docker container name and the SSH alias are both `devenv-<id>`, for example `devenv-env-root-a1b2c3`. The Herdr label is the id, for example `env-root-a1b2c3`.

## Registry

`~/.devenv/herdr/worktrees.json`, mode `0600`, directory mode `0700`:

```json
{
  "version": 1,
  "worktrees": {
    "/abs/path/repo/.git": {
      "id": "env-root-a1b2c3",
      "port": 43107,
      "worktree_path": "/abs/path/repo",
      "git_common_dir": "/abs/path/repo/.git"
    }
  }
}
```

The map key is the absolute, symlink-resolved git directory. `worktree_path` is informational. Under the `<repo>/worktrees/<name>` rule a checkout cannot move without its git directory moving too, and a moved repository is a different key: it gets a new id and a new machine, and the old row stays until `--delete-data`.

Hold an exclusive flock on `~/.devenv/herdr/worktrees.lock` for the create-or-attach decision: resolving the worktree, loading or minting the id and port, inspecting the stable name, and the `docker run` itself. Release the lock as soon as `docker run` returns or the attach decision is made. The ready check and Herdr registration run outside the lock. The ready check can wait 30 seconds and `machine add` can prompt, and neither should block `dev up` in another worktree. Two concurrent `dev` invocations in the same worktree must still end on one container, which the stable name guarantees.

The port is allocated from `43100` through `43999` and then stored in the record. Skip ports already present in the file, and skip `cfg.ProxyPort` even when `DEVENV_PROXY_PORT` is moved into that range. The default proxy port is `23750`. Also probe each candidate: bind `127.0.0.1:<port>` on the Mac and release it, then dial `127.0.0.1:<port>` with a short timeout. Skip the port when the bind fails or the dial connects. The dial matters because Go listeners set `SO_REUSEADDR`, and on macOS a loopback bind can succeed while another process listens on `0.0.0.0:<port>`. The registry only knows about devenv's own ports, and an unrelated listener on the Mac would otherwise make the new container's publish fail. The probe happens under the lock, so two worktrees cannot pick the same port. Never change a worktree's port after it is stored. A recorded port is an error only when a different listener holds it. This worktree's own running container is that listener, so `dev up` does the "already running" check before the port check. The error names the port and the registry file, so a person can free the port or delete the row. Reusing the port for a different worktree would make an old Herdr profile connect to the wrong container.

`devenv down` leaves this file in place. `devenv down --delete-data` removes `~/.devenv`, including the registry, keys, and host keys, and removes the managed include block from `~/.ssh/config`. OpenSSH ignores an `Include` whose file is missing, but the block would point at a deleted file, and the next `dev up` writes it again anyway.

## SSH

Every dev container accepts the same SSH credential. The containers are local, and the listener is published only on the Mac's loopback.

| Material | Path on the Mac | Who has the private half |
| --- | --- | --- |
| Client key | `~/.ssh/devenv_herdr_ed25519` | The Mac only. The container receives the public key. |
| Host key | `~/.devenv/herdr/ssh_host_ed25519_key` | Copied into each container at start for `sshd`. The source of truth stays on the Mac. |

The workspace container bind-mounts all of `~/.devenv` read-only at `/devenv`. The client private key stays outside that tree. `ssh-keygen` writes the public key beside the private key; setup copies only `devenv_herdr_ed25519.pub` to `~/.devenv/herdr/id_ed25519.pub`, which the entrypoint reads at `/devenv/herdr/id_ed25519.pub`.

Generate each key once with `ssh-keygen -t ed25519 -N ""` when the file is absent. Never replace an existing key. Private keys are mode `0600`. This is a different key from `~/.devenv/ssh/id_ed25519`, which remains the outbound Git key and stays mounted at `/home/dev/.ssh`. That private key lives inside the container, so it is the wrong key for logging into the container.

`devenv setup` and `devenv up` create the Herdr keys if they are missing, same as today's Git key.

### sshd

Add `openssh-server` and `tini` to `dev.Dockerfile` on the late, cheap layers. Delete any host keys the package generates at build time. `/run` is empty when the container starts, so the entrypoint creates `/run/sshd` before `sshd`.

`tini` is PID 1 in front of `dev-entrypoint`. There is no one-shot path. The entrypoint does not exec `"$@"` or `CMD ["bash"]`. After it creates the `dev` user, it:

1. Unlocks the account for `sshd` when its shadow password field starts with `!`: `usermod -p '*' "${user_name}"`. Leave any other value alone, so a real hash on a pre-existing user (`LOCAL_ALLOW_EXISTING_USER=1`) survives. `useradd` without a password writes `!` into the shadow entry. With `UsePAM no`, OpenSSH checks that field itself before any authentication method runs and refuses the login with "User dev not allowed because account is locked". A password field of `*` has no valid hash, so password login stays impossible, and `PasswordAuthentication no` is still set. `sudo` is `NOPASSWD`, so nothing else notices.
2. Creates `/run/devenv` as `root:root` mode `0755`, then `/run/sshd`. `sshd` keeps `StrictModes` on, so this directory must not be group-writable.
3. Copies `/devenv/herdr/ssh_host_ed25519_key` and its `.pub` to `/run/devenv/`, both `root:root`, private key mode `0600`.
4. Copies `/devenv/herdr/id_ed25519.pub` to `/run/devenv/authorized_keys`, owned by the container user, mode `0600`.
5. Writes `/etc/ssh/sshd_config.d/devenv.conf`.
6. `chown`s `/var/lib/devenv/herdr` to the container user and creates `/var/lib/devenv/herdr/herdr` with the same owner, mode `0700`. Docker creates the volume as root, and the Herdr server runs as that user.
7. Points Herdr's config directory at the volume with a symlink: `${home_dir}/.config/herdr -> /var/lib/devenv/herdr/herdr`. Create `${home_dir}/.config` owned by the container user when it is missing. If `${home_dir}/.config/herdr` is already a real directory, from a `herdr` run in the old `dev` shell, rename it to `herdr.pre-devenv-<UTC stamp>` and print a warning, then create the symlink. If it is already the right symlink, leave it. The home is the shared `~/.devenv/home` mount, so every container writes the same symlink, and each resolves it to its own volume. This is the only redirect. `XDG_CONFIG_HOME` is never set: it is process-wide, and `gh`, `git`, and other XDG-aware tools in every pane would follow it onto the per-worktree volume, which would make `gh auth login` per worktree and lose it with the volume. If a later Herdr release adds a dedicated config-directory flag or variable, prefer that over the symlink.
8. Writes `/var/lib/devenv/herdr/herdr/config.toml` only when that file is absent, with `install -m 0644 -o "${uid}" -g "${gid}"` so the user-run server can update it. The file sets `onboarding = false` and `[terminal] new_cwd` to `DEVENV_PANE_CWD` (`/workspace` for the main checkout, `/workspace/worktrees/<name>` for a linked worktree). Herdr 0.9.5's default `new_cwd` is `follow`, and with no source pane that starts in `$HOME`, then the process cwd. A fixed path is what puts the first pane in the worktree. Do not overwrite the file once it exists.
9. Starts `herdr server` as the container user, with `HOME` set to that user's home (`/home/dev` unless the entrypoint chose another), and with `USER`, `LOGNAME`, `SHELL`, `CODEX_HOME`, `DOCKER_HOST`, `GIT_CONFIG_GLOBAL`, `CODEX_SQLITE_HOME`, and the image `PATH` exported in the same command. `docker run -e` reaches the entrypoint. It does not reach a server that `sshd` starts later. The `gosu` invocation carries this environment.
10. Runs `/usr/sbin/sshd -D -e` in the foreground. The container does not start a user shell.

`sshd -D` is the container's main process, so the container stays up across shell exits and Herdr client disconnects. `dev down` and `devenv down` remove it. The spike confirms whether `herdr server` stays in the foreground or daemonizes and exits. If it exits zero after daemonizing, the entrypoint treats that as started. If the server process stays in the foreground, the entrypoint backgrounds it and still uses `sshd -D` as the main process. A later SSH session from `herdr machine add` can start the server when it is not running. `sshd` has to be up for that.

`dev up` only runs `machine add` for a new profile, so a server that dies later needs another path back. The spike kills `herdr server` inside a running container and records whether the Mac client starts it again on reconnect. If the client does, nothing more is needed. If it does not, the entrypoint supervises the server as the container user. For a server that stays in the foreground: wait for it to exit, log the exit status, sleep a few seconds, start it again. For a server that daemonizes, the launched process exits zero at once, so that loop would start a new server every few seconds. In that case the loop instead sleeps, checks liveness (`herdr.sock` present and `herdr server status` or an equivalent succeeds), and only starts the server when the check fails. The loop is a background job of the entrypoint shell and gets reparented to `tini` when the shell execs `sshd`.

`sshd_config.d/devenv.conf`:

```text
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UseDNS no
UsePAM no
PrintMotd no
PrintLastLog no
Banner none
PermitUserRC no
PermitUserEnvironment no
AllowUsers <container user>
AuthorizedKeysFile /run/devenv/authorized_keys
HostKey /run/devenv/ssh_host_ed25519_key
PidFile /run/sshd.pid
SetEnv HOME=<container home> USER=<container user> LOGNAME=<container user> SHELL=/bin/bash CODEX_HOME=<container home>/.codex CODEX_SQLITE_HOME=/var/lib/codex-sqlite DOCKER_HOST=tcp://devenv-dockerproxy:2375 GIT_CONFIG_GLOBAL=/devenv/gitconfig PATH=<image PATH>
```

Every variable sits on one `SetEnv` line. OpenSSH 9.2, the version in Debian bookworm, keeps only the first `SetEnv` directive it reads; later ones are dropped silently, and `sshd -T` shows which survived. `SHELL` is on the line because Herdr opens panes with `$SHELL` and falls back to `/bin/sh` when it is unset.

`AllowUsers` is the username the entrypoint actually created (`LOCAL_USER_NAME`, default `dev`). The SSH config on the Mac uses that same name. The default remains `dev`.

`AuthorizedKeysFile` and `HostKey` point at `/run`, which is a normal Linux filesystem inside the container. `sshd` rejects keys whose owner or mode is wrong. Files on the macOS bind mount of `~/.devenv` are the wrong place for those checks. The entrypoint copies them and sets ownership on every start, so a recreated container presents the same host key.

Herdr 0.9.5 resolves its config directory from `XDG_CONFIG_HOME` when that variable is set and from `~/.config` otherwise (`config_dir()` in the 0.9.5 `src/config/io.rs`), and the server sockets (`herdr.sock`, `herdr-client.sock`) live under that directory. The `~/.config/herdr` symlink from the entrypoint is what puts that directory on the volume, for the supervised server and for every non-interactive SSH command Herdr runs. OpenSSH's default `AcceptEnv` does not include `XDG_CONFIG_HOME` and `PermitUserEnvironment` is off, so a client cannot point the remote server somewhere else. Nothing in `devenv.conf` sets `XDG_CONFIG_HOME`, for the reason given at step 7. `PermitUserRC no` keeps `~/.ssh/rc` from writing extra bytes onto the SSH stream Herdr uses.

`UsePAM no` keeps Debian's `pam_env` from replacing `PATH` after `SetEnv`. With PAM off, `pam_motd` does not run either, and `sshd` does its own locked-account check, which is why the entrypoint unlocks the account at step 1. `SetEnv` is what an SSH-started `herdr server` actually inherits. It repeats `DOCKER_HOST`, `GIT_CONFIG_GLOBAL`, and `CODEX_SQLITE_HOME` from today's `devDockerRunArgs`, plus `HOME` and the image `PATH` (Go, Cargo, pnpm, linuxbrew, and `/usr/local/bin`). The spike confirms `ssh <alias> herdr --version` prints the pinned version, `ssh <alias> printenv DOCKER_HOST GIT_CONFIG_GLOBAL CODEX_SQLITE_HOME` prints those values, `ssh <alias> printenv XDG_CONFIG_HOME` prints nothing, and Herdr uses `/usr/local/bin/herdr` rather than installing a second binary under `~/.local/bin`.

Inside the container, `sshd` listens on port 22 on all container interfaces. Docker publishes that port only as `127.0.0.1:<port>:22`. Other containers on `devenv-dockerproxy-net` can open a TCP connection to it. They do not have the client private key.

### SSH config on the Mac

`devenv up` writes `~/.devenv/herdr/ssh_config` from the registry on every run, after the registry update and before the ready check, and installs the managed include at the top of `~/.ssh/config`. `devenv setup` installs the include too, so it exists before the first `dev up`, and renders `ssh_config` from whatever the registry holds, which may be no host blocks. No other command touches either file except `down --delete-data`. The include uses the same replace-in-place approach as the zshrc block:

```text
# >>> devenv herdr >>>
Include /abs/path/.devenv/herdr/ssh_config
# <<< devenv herdr <<<
```

The include stays at the top so these `Host` blocks are seen before a general `Host *` block. Create `~/.ssh/config` mode `0644` when it is missing. Create `~/.ssh` mode `0700` when it is missing. Leave every line outside the managed block alone.

`ssh_config` contents:

```text
Host devenv-*
  User dev
  IdentityFile /abs/path/.ssh/devenv_herdr_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile /abs/path/.devenv/herdr/known_hosts
  StrictHostKeyChecking accept-new

Host devenv-env-root-a1b2c3
  HostName 127.0.0.1
  Port 43107
```

`User` follows the container user when it is not `dev`. `IdentitiesOnly yes` limits this alias to the Herdr key. `UserKnownHostsFile` keeps these host keys out of the user's normal `known_hosts`. `accept-new` records the key on the first successful connection. The next container presents the same key, so the check succeeds.

`devenv down` leaves the include and the host blocks in place. The alias has to keep resolving while the container is stopped, because that is the saved Herdr target. `devenv down --delete-data` removes the managed block from `~/.ssh/config` along with `~/.devenv`, and leaves every other line alone.

## Container lifecycle

Today `devenv run` is `docker run --rm`, and `dev` with no arguments opens a shell in that container. `dev <command>` runs that command the same way. This work removes both. The shell and the one-shot command are a second client next to Herdr, and a one-shot container is a second dev env for the same worktree.

The user-facing commands are `dev up` and `dev down`. `dev` with no arguments, or `dev` with any other command, prints usage and exits non-zero. `devenv run` is removed.

`dev up` starts the workspace container and returns. `sshd` is its main process. Closing the Herdr client leaves the server and its panes running. There is no shell attach.

`dev down` is `devenv stop`. It removes that worktree's container and nothing else. With no container running, it succeeds. The proxy, other worktrees, the Herdr profile, the SSH alias, the registry row, the host key, and the Herdr volume stay. `devenv down` stays the global teardown: every managed container for this root, including the proxy.

The generated zsh function accepts only `up` and `down`. Today `dev()` forwards every argument after `--`, so `dev up` would otherwise run a program named `up` inside the container. The function keeps passing `--quiet`, which routes progress lines through `status()` and discards them. Lines the user has to act on do not go through `status()`: the "install herdr" hint, the exact `machine add` line, the ready-check timeout with its `docker logs` hint, and the busy-port error all print to stderr unconditionally. Add a `notice()` helper next to `status()` for that, and use it for every message that names a command to run.

`devenv up` runs the current `runContainer` prelude before it takes the worktree lock: `ensureLayout`, `ensureGitconfig`, `ensureSSH`, Herdr key setup, and `ensureProxy`. `devenv down` removes the proxy container and `devenv-dockerproxy-net`. The next `dev up` has to create them again, or `docker run --network` fails.

For a worktree, under the registry lock:

1. Resolve the worktree. Outside a worktree, `dev up` and `dev down` fail.
2. Load or mint its id and port.
3. Find a container with label `com.aduermael.env.devenv.worktree-gitdir=<git dir>` and `com.aduermael.env.devenv.root=<cfg.Root>`.
4. `dev down` removes that container when it exists and returns. It does not remove the registry row.
5. If the workspace container is running, `dev up` releases the lock, ensures Herdr registration, and returns. It does not check whether the published port is busy, and it does not create another container.
6. If a stopped container still holds the stable name, `docker rm -f` it and continue. This is also how a container from the previous image is replaced: `dev down`, then `dev up`.
7. `dev up` creates the workspace container.
8. If `docker run --name` loses a race, inspect the winner. Use it when it is this worktree. Return an error when the name belongs to something else.

The stable name is the mutual exclusion. A second container for the worktree cannot take it.

The workspace container is started detached (`docker run -d`) with `--restart unless-stopped`. After a Docker restart it comes back with the same name, port, and host key, and Herdr reconnects. `dev down` uses `docker rm -f`, so a stopped worktree stays stopped. The CLI does not need to remain running for the container to stay up.

`devenv setup` rebuilding the image does not replace a running workspace container. The new image is used the next time `dev up` creates the container.

`devenv down` still removes every container with `com.aduermael.env.devenv.managed=true` and this root, including the proxy and any workspace container. The Herdr profile, SSH alias, registry row, host key, and Herdr volume remain. The next `dev up` creates a new container on the same alias.

### Create arguments

Use the mounts, labels, network, and env that `devDockerRunArgs` uses today, and add serve-mode settings:

```text
docker run -d --restart unless-stopped
  --name devenv-<id>
  --label com.aduermael.env.devenv.managed=true
  --label com.aduermael.env.devenv.role=workspace
  --label com.aduermael.env.devenv.root=<cfg.Root>
  --label com.aduermael.env.devenv.worktree-gitdir=<abs git dir>
  --label com.aduermael.env.devenv.machine-id=<id>
  --network devenv-dockerproxy-net
  -p 127.0.0.1:<port>:22
  -e DEVENV_PANE_CWD=/workspace/worktrees/<name>
  -e LOCAL_USER_ID=...
  -e LOCAL_GROUP_ID=...
  -e DOCKER_HOST=tcp://devenv-dockerproxy:2375
  -e GIT_CONFIG_GLOBAL=/devenv/gitconfig
  -v <repo root>:/workspace
  -v <repo root>:<repo root>
  --mount type=bind,source=<root>,target=/devenv,readonly
  --mount type=bind,source=<root>/home,target=/home/dev
  --mount type=bind,source=<root>/ssh,target=/home/dev/.ssh
  --mount type=volume,source=devenv-herdr-<id>,target=/var/lib/devenv/herdr
  --mount type=volume,source=devenv-dockerproxy-codex-sqlite,target=/var/lib/codex-sqlite
  -e CODEX_SQLITE_HOME=/var/lib/codex-sqlite
  local-dev:latest
```

The network name and Codex volume name already come from `proxyNetworkName` and `codexSqliteVolumeName`. The proxy container default is `devenv-dockerproxy`. `DOCKER_HOST` uses that container name. The second bind mount is omitted when the repository root is already `/workspace`. `<repo root>` is the parent of the main `.git`, for both the main checkout and a `worktrees/<name>` checkout.

Publish `127.0.0.1`, not `0.0.0.0`. On OrbStack, published ports are reachable from the LAN unless the bind address is loopback or "Expose ports to LAN" is off. The spike confirms loopback publish stays on the Mac for both Docker Desktop and OrbStack.

`-d` with no `-t` on create. There is no `--rm`: the container stays after `dev up` returns, and `dev down` removes it. The container does not need the caller's `TERM`. Herdr allocates its own ptys.

Create the Herdr volume with labels `com.aduermael.env.devenv.managed=true`, `com.aduermael.env.devenv.role=herdr`, `com.aduermael.env.devenv.root=<cfg.Root>`, and `com.aduermael.env.devenv.machine-id=<id>`. `devenv down` without `--delete-data` leaves the volume. `devenv down --delete-data` removes volumes with those managed and root labels, along with the existing Codex SQLite volume.

The `~/.config/herdr` symlink makes Herdr store its config and sockets at `/var/lib/devenv/herdr/herdr/` on that volume. The volume is per machine id, so two worktrees do not share sockets. The shared `~/.devenv/home` bind mount stays the place for tool state such as `~/.codex`. Herdr sockets stay off that mount: it is shared by every container, and it is a macOS virtiofs mount.

The config directory is the only Herdr path this plan has confirmed. The spike lists every path `herdr server` writes during a session with a couple of panes, for example by comparing `find "$HOME" -newer /run/sshd.pid` before and after. Any `herdr` directory it creates under `~/.local/share`, `~/.local/state`, or `~/.cache` gets the same treatment: the entrypoint creates a sibling directory on the volume (`/var/lib/devenv/herdr/data`, `state`, `cache`) and a symlink from the home path onto it, with the same rename-aside rule for a pre-existing real directory. Session files and layouts must not live on the shared home, or two worktrees would overwrite each other's state. Record the final list of symlinks in the implementation PR.

### Ready check

After creating a workspace container, retry `ssh -o BatchMode=yes devenv-<id> true` for up to 30 seconds. This uses the alias, so `accept-new` writes `~/.devenv/herdr/known_hosts` before Herdr connects. On timeout, print the container name and a `docker logs` hint, remove the container just created, and do not register a Herdr machine.

`dev up` runs registration after that check and then returns. If `machine add` fails, print the error. The container stays up.

## Herdr registration

After SSH is healthy, on `dev up` only:

```text
herdr machine list --json
herdr machine add devenv-<id> --label "<id>" --remote-session default
```

Skip `machine add` when the JSON list already contains that SSH target. Match the target, not the label. A renamed label is still the same machine. The spike records the exact JSON fields from `herdr machine list --json` on the client version under test, and confirms the saved target is the alias `devenv-<id>`. Herdr's machine is the string it stored. A saved alias keeps the same machine when only the port behind that alias changes. A saved `127.0.0.1` and port means the recorded port is part of the machine and must stay fixed.

`machine add` may prompt before it installs or replaces a remote server. Run it on the user's terminal so they can answer. The image already contains a compatible `herdr`, so a prompt to install means the Mac client rejected the pinned binary. Do not accept an install into `~/.local/bin`. Stop and bump the image pin with `scripts/update-herdr.sh` so the server stays the image binary.

`machine add` starts the remote `default` session when it is not already running, then saves the profile. An open local `herdr` shows the new machine within about a second.

When `herdr` is not on the Mac `PATH`, `dev up` still succeeds. Print the install command and the exact `machine add` line.

`dev up` is the only command that runs `machine add`. Run it on a terminal when Herdr may prompt. A non-interactive `dev up` that would need a prompt prints the `machine add` line and leaves the container up.

`devenv down` does not run `herdr machine remove`. The profile stays and goes offline. `--delete-data` removes the keys and the registry, which orphans existing profiles. Tell the user to remove them with `herdr machine remove <profile-id>` after reading `herdr machine list`.

Do not set `ForwardAgent`. Git from panes uses the key mounted at `/home/dev/.ssh`.

## Version check

Saved machines need the remote server's `surface_interest` and `health_check` capabilities. Herdr connects different client and server versions when both sides speak the stable endpoint generation.

The spike runs the current stable macOS `herdr` against the image pin. If `machine add` reports the server as missing those capabilities, the implementation PR bumps `HERDR_VERSION` and both checksums through `scripts/update-herdr.sh`, then re-runs `scripts/test-herdr-pin.sh` and `scripts/test-update-herdr.sh`. The Mac client stays on a release that accepts that server.

## Spike

Do this on a Mac, against Docker Desktop and OrbStack, before changing `cmd/devenv`. A throwaway container from the current image is enough. Record the results in the implementation PR.

- `ssh -o BatchMode=yes` to `127.0.0.1:<port>` as the container user, with the shared key, succeeds. `ssh <alias> herdr --version` prints only the version line. `ssh <alias> printenv HOME DOCKER_HOST GIT_CONFIG_GLOBAL CODEX_SQLITE_HOME` prints the container home, the proxy URL, `/devenv/gitconfig`, and `/var/lib/codex-sqlite`.
- In a linked worktree at `<repo>/worktrees/<name>`, `git status` succeeds in the container. The first Herdr pane's cwd is `/workspace/worktrees/<name>`.
- `devenv down` then `dev up` recreates the proxy network and the workspace container.
- `herdr machine add <alias> --label <id> --remote-session default` saves a profile and the machine appears in a local `herdr`.
- Herdr connects through the system `ssh` and honors `~/.ssh/config`. Comment out the managed include, restart the local `herdr`, and the machine must become unreachable. Put the include back and it must reconnect. If Herdr uses its own SSH implementation instead, the alias, `IdentityFile`, and `UserKnownHostsFile` in this plan do not apply, and the plan has to be revised before implementation.
- Kill `herdr server` inside a running container with the Mac client connected. Record whether the client starts it again, and whether a disconnect and reconnect does. This decides whether the entrypoint needs the restart loop.
- Every path `herdr server` writes under `$HOME` is on the per-machine volume, via the config symlink or one of the sibling symlinks. `gh auth status` in a pane reads the shared `~/.config/gh`, not the volume, and `printenv XDG_CONFIG_HOME` in a pane prints nothing.
- `ssh <alias> true` succeeds with `UsePAM no` and the unlocked account. `docker logs` shows no "account is locked" line.
- Stop the container. The row goes dim. Start another container on the same alias, port, and host key. The same profile becomes reachable without `machine add` and without a host-key prompt.
- A second container that presents a new host key on that alias makes Herdr show attention.
- Herdr sockets exist under the named volume. `herdr machine status <label> --json` reports the machine reachable.
- The published port is not reachable from another host on the LAN.
- `herdr server` either stays in the foreground or daemonizes. The entrypoint matches that behavior.
- A headless `herdr server` starts without a TTY.

If loopback publish fails on one runtime, stop and revise this plan. A `ProxyCommand` through `docker exec` is a different SSH shape and needs its own proof with Herdr's generated SSH config (`remote.manage_ssh_config`). It is not the design in this plan.

## CLI and image changes

Image, in `dev.Dockerfile`:

- Install `openssh-server` and `tini`.
- Remove build-time host keys.
- Set `ENTRYPOINT ["tini", "--", "/usr/local/bin/dev-entrypoint"]`.
- Extend `dev-entrypoint` with the serve-mode steps above. Leave the existing user, home, and Claude settings setup in place. The entrypoint unlocks the account, exports `HOME` and the dev environment, writes the `~/.config/herdr` symlink, starts `herdr server` as that user, and execs `sshd -D`. It does not exec `"$@"` or `CMD ["bash"]`.

CLI, in `cmd/devenv/main.go`:

- Create `~/.devenv/herdr` from `ensureLayout`.
- Generate Herdr keys from `setup` and `up`, next to `ensureSSH`.
- Add worktree resolution, registry load/store, port allocation, and SSH config rendering as pure functions with tests. Port allocation takes the probe as a function value so tests can fake a busy port.
- Add a `notice()` helper that writes to stderr regardless of `--quiet`, for messages that name a command the user must run.
- Render `~/.devenv/herdr/ssh_config` and install the `~/.ssh/config` include from `setup` and `up`. Remove the include from `down --delete-data`.
- Add `devenv up` and `devenv stop` (the per-worktree stop). Replace the generated `dev` function so it accepts only `up` and `down`. `dev down` calls `devenv stop`. Anything else prints usage. `devenv down` remains the global command.
- Remove `devenv run` and `devDockerRunArgs`. `dev up` ensures the detached workspace container. `dev down` removes that worktree's container.
- Extend `down --delete-data` to remove Herdr volumes labeled for this root and the managed block in `~/.ssh/config`.
- Update the usage text in `printUsage`.

Docs, in `README.md`:

- `dev up` starts the worktree container and returns. `dev down` removes that container. `devenv down` is unchanged and still removes every managed container.
- `dev` no longer opens a shell or runs a command. `devenv run` is removed. Work happens in Herdr panes. `gh auth login` runs there after `dev up`.
- The container is a Herdr machine while it is up. The same worktree keeps the same machine the next time `dev up` starts it.
- State layout gains `herdr/` (host key, public key, `worktrees.json`, `ssh_config`, `known_hosts`). The client private key is `~/.ssh/devenv_herdr_ed25519`.
- `~/.devenv/home/.config/herdr` is a symlink onto the per-worktree Herdr volume. Herdr config and sockets are per worktree. Other tool config under `~/.config`, such as `gh`, stays shared.
- Linked worktrees live at `<repo>/worktrees/<name>`. Add `worktrees/` to `.git/info/exclude` so the main checkout does not list them as untracked.
- `dev up` outside a worktree fails.
- Rebuilding the image does not restart a running workspace container.

## Tests

Unit tests in `cmd/devenv/main_test.go`, without Docker:

- Main worktree, `<repo>/worktrees/<name>`, a subdirectory of each, and a submodule inside either, from fixture directories. A linked worktree outside `worktrees/<name>` is an error. A submodule resolves to the enclosing worktree. The mount source is the repository root, and the pane directory is `/workspace` or `/workspace/worktrees/<name>`.
- A linked worktree at `worktrees/feature` whose `.git` file points at `.git/worktrees/feature1` resolves with name `feature` and pane directory `/workspace/worktrees/feature`.
- A worktree reached through a symlinked parent directory resolves to the same registry key, id, and mount source as the real path.
- A directory with no `.git` is not a worktree. A relative `gitdir:` and a relative `commondir` become absolute registry keys.
- Slug sanitization, length cap, and suffix collision retry.
- The same git directory returns the same id and port. A second worktree gets another id and port.
- Allocation skips a port the probe reports busy and skips the proxy port, then stores the first free one.
- A recorded port that is busy is an error, and the stored port is unchanged.
- `--delete-data` removes the managed block from an `~/.ssh/config` fixture and leaves the other lines.
- SSH config contains one shared `Host devenv-*` block and one port block per worktree. The managed include is inserted at the top of an existing `~/.ssh/config` and replaced in place on the next write. Lines outside the block stay.
- Existing keys are left in place when ensure runs again.
- Tests that assert `devenv run` or `devDockerRunArgs` are removed with those functions.

The Mac spike covers Docker Desktop, OrbStack, Herdr reconnect, and the single-container rule. `herdr machine list --json` shows the saved target is the alias. `dev up` returns with the container still running. A Herdr pane keeps running after the Mac client detaches. `dev` with no arguments, and `dev ls`, print usage and do not start a container. `dev down` removes that container and leaves another worktree's container running. `dev up` in a linked worktree of the same repo gets a second container and a second Herdr machine. `devenv setup` while a workspace container is running leaves that container on its current image.

## Codex SQLite

Codex stores its logs and thread index in SQLite. On a macOS bind mount that file can grow to multiple gigabytes and stall Codex startup, so `devenv` puts it on one Linux volume, `devenv-dockerproxy-codex-sqlite`, mounted at `/var/lib/codex-sqlite`. Every dev container already shares that volume. This plan leaves it shared. Two worktrees running Codex at the same time write one database. Splitting the volume per worktree is a separate change.

## Out of scope

- The Herdr desktop app and `herdr-core`.
- Changing `devenv down` into a per-worktree command. Per-worktree stop is `dev down`.
- Replacing a running container because the image was rebuilt.
- A per-worktree Codex SQLite volume.
- An interactive `dev` shell, and `dev <command>` / `devenv run`.
- Automatic removal of Herdr profiles.
- SSH agent forwarding.
- Publishing port 22 on any address other than `127.0.0.1`.
