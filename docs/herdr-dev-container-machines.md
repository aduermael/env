# Herdr machines for dev containers

A macOS Herdr TUI connects to dev-env containers as saved SSH machines. Each git worktree has at most one dev container. Recreating that container brings the same Herdr machine back.

This is the implementation plan. It describes behavior to build. It does not change the image or the CLI by itself.

## Client

The Mac client is the Herdr TUI (`herdr`). The image already installs that binary, pinned in `dev.Dockerfile` as `HERDR_VERSION` (currently 0.9.5).

The Herdr desktop app is a different program. It talks to `herdr-core` (`hc`). The TUI server and `herdr-core` do not share agents. This plan does not install `hc` and does not register machines with the desktop app.

Herdr shows panes that belong to the remote Herdr server. A process started from a plain shell in the container stays outside that sidebar. `dev` remains a shell. Agents that should appear in Herdr are started from the Herdr client, in a pane on that machine.

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
- linked worktree: `<repo>/.git/worktrees/<name>`
- submodule: the submodule's own git directory, the first `.git` found walking up from the current directory

Resolve it on the Mac before the container starts, by walking parent directories. Do not require a `git` binary on the Mac.

- A `.git` directory means this is the main worktree. Its git directory is that path.
- A `.git` file containing `gitdir: <path>` means a linked worktree or a submodule. `<path>` is the git directory. `<path>/commondir`, when present, resolves to the main `.git`.

`dev` from a subdirectory uses that worktree. The container mounts the worktree root at `/workspace`. An interactive shell, and `dev <command>`, start in the subdirectory the user launched from (`docker exec -w`).

A directory that is not inside a worktree keeps today's behavior: `docker run --rm`, no name, no SSH, no Herdr registration.

### Machine id

Mint the id once, the first time a worktree gets a dev container. Store it in the worktree record. Later runs reuse it.

```text
<repo-slug>-<worktree-slug>-<6 random chars>
```

- `repo-slug` is the directory name of the main checkout (the parent of the common `.git`), sanitized. When `commondir` is absent, use the directory that contains the `.git` that was found.
- `worktree-slug` is `root` for the main worktree. For a linked worktree it is the final path component of `<repo>/.git/worktrees/<name>`. For a submodule git directory under `.git/modules/`, it is the module name. Sanitize that component.
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

The map key is the absolute git directory. Update `worktree_path` when a linked worktree has moved and its git directory is unchanged.

Hold an exclusive flock on `~/.devenv/herdr/worktrees.lock` for the whole create-or-attach decision, including the registry update and the `docker run`. Two concurrent `dev` invocations in the same worktree must end on one container.

The port is allocated from `43100` through `43999` and then stored in the record. Skip ports already present in the file. `23750` is the Docker socket proxy and is outside this range. Never change a worktree's port after it is stored. A recorded port that is held by some other process is an error that names the id and the port. Reusing the port for a different worktree would make an old Herdr profile connect to the wrong container.

`devenv down` leaves this file in place. `devenv down --delete-data` removes `~/.devenv`, including the registry, keys, and host keys.

## SSH

Every dev container accepts the same SSH credential. The containers are local, and the listener is published only on the Mac's loopback.

| Material | Path on the Mac | Who has the private half |
| --- | --- | --- |
| Client key | `~/.devenv/herdr/id_ed25519` | The Mac only. The container receives the public key. |
| Host key | `~/.devenv/herdr/ssh_host_ed25519_key` | Copied into each container at start for `sshd`. The source of truth stays on the Mac. |

Generate each key once with `ssh-keygen -t ed25519 -N ""` when the file is absent. Never replace an existing key. Private keys are mode `0600`. This is a different key from `~/.devenv/ssh/id_ed25519`, which remains the outbound Git key and stays mounted at `/home/dev/.ssh`. That private key lives inside the container, so it is the wrong key for logging into the container.

`devenv setup` and `devenv run` create the Herdr keys if they are missing, same as today's Git key.

### sshd

Add `openssh-server` and `tini` to `dev.Dockerfile` on the late, cheap layers. Delete any host keys the package generates at build time. `/run` is empty when the container starts, so the entrypoint creates `/run/sshd` before `sshd`.

`tini` is PID 1 in front of `dev-entrypoint`. One-shot containers still end in `exec` of the user command.

Serve mode is `DEVENV_SERVE=1`. After the entrypoint creates the `dev` user, it:

1. Copies the host private key and its `.pub` to `/run/devenv/ssh_host_ed25519_key` and `/run/devenv/ssh_host_ed25519_key.pub`, both `root:root`, private key mode `0600`.
2. Copies the client public key to `/run/devenv/authorized_keys`, owned by the container user, mode `0600`.
3. Writes `/etc/ssh/sshd_config.d/devenv.conf`.
4. `chown`s `/var/lib/devenv/herdr` to the container user. Docker creates the volume as root, and the Herdr server runs as that user.
5. Writes `/var/lib/devenv/herdr/herdr/config.toml` with `onboarding = false` only when that file is absent. Herdr's config directory is `$XDG_CONFIG_HOME/herdr`.
6. Starts `herdr server` as the container user, with `XDG_CONFIG_HOME=/var/lib/devenv/herdr`.
7. Runs `/usr/sbin/sshd -D -e` in the foreground.

`sshd` is the process that keeps the container up. The Herdr server is started beside it. The spike confirms whether `herdr server` stays in the foreground or daemonizes and exits. If it exits zero after daemonizing, the entrypoint treats that as started. If the server process is still in the foreground, the entrypoint backgrounds it and still uses `sshd -D` as the main process. A later SSH session from `herdr machine add` can start the server when it is not running. `sshd` has to be up for that.

`sshd_config.d/devenv.conf`:

```text
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UseDNS no
PrintMotd no
PrintLastLog no
Banner none
PermitUserRC no
PermitUserEnvironment no
AllowUsers <container user>
AuthorizedKeysFile /run/devenv/authorized_keys
HostKey /run/devenv/ssh_host_ed25519_key
PidFile /run/sshd.pid
SetEnv XDG_CONFIG_HOME=/var/lib/devenv/herdr
SetEnv PATH=<image PATH>
```

`AllowUsers` is the username the entrypoint actually created (`LOCAL_USER_NAME`, default `dev`). The SSH config on the Mac uses that same name. The default remains `dev`.

`AuthorizedKeysFile` and `HostKey` point at `/run`, which is a normal Linux filesystem inside the container. `sshd` rejects keys whose owner or mode is wrong. Files on the macOS bind mount of `~/.devenv` are the wrong place for those checks. The entrypoint copies them and sets ownership on every start, so a recreated container presents the same host key.

`SetEnv XDG_CONFIG_HOME` matters because Herdr 0.9.5 resolves its config directory from `XDG_CONFIG_HOME` when that variable is set (`config_dir()` in the 0.9.5 `src/config/io.rs`), and the server sockets (`herdr.sock`, `herdr-client.sock`) live under that directory. The supervised server and every non-interactive SSH command Herdr runs must see the same directory. OpenSSH's default `AcceptEnv` does not include `XDG_CONFIG_HOME`, so a client cannot point the remote server at a different directory. `PermitUserRC no` keeps `~/.ssh/rc` from writing extra bytes onto the SSH stream Herdr uses.

`SetEnv PATH` includes `/usr/local/bin`, where the image installs `herdr`. Non-interactive SSH often has a default `PATH` that omits it. The spike confirms `ssh <alias> herdr --version` prints the pinned version and that Herdr uses `/usr/local/bin/herdr` rather than installing a second binary under `~/.local/bin`.

Inside the container, `sshd` listens on port 22 on all container interfaces. Docker publishes that port only as `127.0.0.1:<port>:22`. Other containers on `devenv-dockerproxy-net` can open a TCP connection to it. They do not have the client private key.

### SSH config on the Mac

Write `~/.devenv/herdr/ssh_config` whenever the registry changes. Put a managed include at the top of `~/.ssh/config`, using the same replace-in-place approach as the zshrc block:

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
  IdentityFile /abs/path/.devenv/herdr/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile /abs/path/.devenv/herdr/known_hosts
  StrictHostKeyChecking accept-new

Host devenv-env-root-a1b2c3
  HostName 127.0.0.1
  Port 43107
```

`User` follows the container user when it is not `dev`. `IdentitiesOnly yes` limits this alias to the Herdr key. `UserKnownHostsFile` keeps these host keys out of the user's normal `known_hosts`. `accept-new` records the key on the first successful connection. The next container presents the same key, so the check succeeds.

`devenv down` leaves the include and the host blocks in place. The alias has to keep resolving while the container is stopped, because that is the saved Herdr target.

## Container lifecycle

Today `devDockerRunArgs` in `cmd/devenv/main.go` is `docker run --rm` with no container name and no published port. The container exits with the command, and the Mac has no SSH address for it. Serve mode is a different `docker run` for worktrees. The one-shot arguments stay for directories that are not a worktree.

For a worktree, `devenv run` (what `dev` calls) does this under the registry lock:

1. Resolve the worktree. Load or mint its id and port.
2. Find a container with label `com.aduermael.env.devenv.worktree-gitdir=<git dir>` and `com.aduermael.env.devenv.root=<cfg.Root>`.
3. If one is running, use it.
4. If one exists and is stopped, `docker rm -f` it. Then create a new container with the same name, port, host key, and Herdr volume.
5. If none exists, create one.
6. If a running container for that git directory exists under a different name, stop and report that name. Do not mint a second id to get around it.
7. If `docker run --name` loses a race, inspect the winner. Attach when it is this worktree. Return an error when the name belongs to something else.

A running container blocks creation. `dev` and `dev <command>` exec into it. They do not start another container. The first `dev` or `dev <command>` in a worktree with no container starts the long-lived one and leaves it running after the command exits. Exiting the shell does not stop it.

`devenv down` already removes every container with `com.aduermael.env.devenv.managed=true` and this root, including the proxy. That includes these workspace containers. The Herdr profile, SSH alias, registry row, host key, and Herdr volume remain. The next `dev` creates a new container on the same alias.

### Create arguments

Keep the current mounts, labels, network, and env from `devDockerRunArgs`, and add serve-mode settings:

```text
docker run -d
  --name devenv-<id>
  --label com.aduermael.env.devenv.managed=true
  --label com.aduermael.env.devenv.role=workspace
  --label com.aduermael.env.devenv.root=<cfg.Root>
  --label com.aduermael.env.devenv.worktree-gitdir=<abs git dir>
  --label com.aduermael.env.devenv.machine-id=<id>
  --network devenv-dockerproxy-net
  -p 127.0.0.1:<port>:22
  -e DEVENV_SERVE=1
  -e LOCAL_USER_ID=...
  -e LOCAL_GROUP_ID=...
  -e DOCKER_HOST=tcp://devenv-dockerproxy:2375
  -e GIT_CONFIG_GLOBAL=/devenv/gitconfig
  -v <worktree root>:/workspace
  --mount type=bind,source=<root>,target=/devenv,readonly
  --mount type=bind,source=<root>/home,target=/home/dev
  --mount type=bind,source=<root>/ssh,target=/home/dev/.ssh
  --mount type=volume,source=devenv-herdr-<id>,target=/var/lib/devenv/herdr
  --mount type=volume,source=devenv-dockerproxy-codex-sqlite,target=/var/lib/codex-sqlite
  -e CODEX_SQLITE_HOME=/var/lib/codex-sqlite
  local-dev:latest
```

The network name and Codex volume name already come from `proxyNetworkName` and `codexSqliteVolumeName`. The proxy container default is `devenv-dockerproxy`.

Publish `127.0.0.1`, not `0.0.0.0`. On OrbStack, published ports are reachable from the LAN unless the bind address is loopback or "Expose ports to LAN" is off. The spike confirms loopback publish stays on the Mac for both Docker Desktop and OrbStack.

`-d` with no `-t`. The client TTY is allocated later by `docker exec -it`.

Pass `TERM`, `COLORTERM`, and the other variables in `forwardedTerminalEnv()` on the `docker exec`, because the detached container does not see the caller's terminal.

Create the Herdr volume with labels `com.aduermael.env.devenv.managed=true`, `com.aduermael.env.devenv.role=herdr`, `com.aduermael.env.devenv.root=<cfg.Root>`, and `com.aduermael.env.devenv.machine-id=<id>`. `devenv down` without `--delete-data` leaves the volume. `devenv down --delete-data` removes volumes with those managed and root labels, along with the existing Codex SQLite volume.

`XDG_CONFIG_HOME=/var/lib/devenv/herdr` makes Herdr store its files at `/var/lib/devenv/herdr/herdr/` on that volume. The volume is per machine id, so two worktrees do not share sockets or session files. The shared `~/.devenv/home` bind mount stays the place for tool state such as `~/.codex`. Herdr sockets stay off that mount: it is shared by every container, and it is a macOS virtiofs mount.

### Attach

Interactive `dev`:

```text
docker exec -it -u <user> -w <workdir> <container> bash
```

`dev <command>`:

```text
docker exec -u <user> -w <workdir> <container> <command>
```

`<workdir>` is `/workspace` plus the relative path from the worktree root to the current directory. Add `-t` when stdin and stdout are terminals, matching today's `devDockerRunArgs` rule.

Wait until `ssh -o BatchMode=yes devenv-<id> true` succeeds before exec or registration. On failure, print the container name and a `docker logs` hint, and do not register a Herdr machine.

On an interactive `dev`, run registration after that check and before `docker exec`, so an install prompt is visible. If `machine add` fails, print the error and still open the shell.

## Herdr registration

After SSH is healthy, on an interactive `dev` only:

```text
herdr machine list --json
herdr machine add devenv-<id> --label "<id>" --remote-session default
```

Skip `machine add` when the JSON list already contains that SSH target. Match the target, not the label. A renamed label is still the same machine. The spike records the exact JSON fields from `herdr machine list --json` on the client version under test.

`machine add` may prompt before it installs or replaces a remote server. Run it on the user's terminal so they can answer. The image already contains a compatible `herdr`, so a prompt to install means the Mac client rejected the pinned binary. Do not accept an install into `~/.local/bin`. Stop and bump the image pin with `scripts/update-herdr.sh` so the server stays the image binary.

`machine add` starts the remote `default` session when it is not already running, then saves the profile. An open local `herdr` shows the new machine within about a second.

When `herdr` is not on the Mac `PATH`, `dev` still succeeds. Print the install command and the exact `machine add` line.

Non-interactive `dev <command>` does not run `machine add`. If the profile is missing and `herdr` exists, print the `machine add` line. A script must not hang on an install prompt.

`devenv down` does not run `herdr machine remove`. The profile stays and goes offline. `--delete-data` removes the keys and the registry, which orphans existing profiles. Tell the user to remove them with `herdr machine remove <profile-id>` after reading `herdr machine list`.

Do not set `ForwardAgent`. Git from panes uses the key mounted at `/home/dev/.ssh`.

## Version check

Saved machines need the remote server's `surface_interest` and `health_check` capabilities. Herdr connects different client and server versions when both sides speak the stable endpoint generation.

The spike runs the current stable macOS `herdr` against the image pin. If `machine add` reports the server as missing those capabilities, the implementation PR bumps `HERDR_VERSION` and both checksums through `scripts/update-herdr.sh`, then re-runs `scripts/test-herdr-pin.sh` and `scripts/test-update-herdr.sh`. The Mac client stays on a release that accepts that server.

## Spike

Do this on a Mac, against Docker Desktop and OrbStack, before changing `cmd/devenv`. A throwaway container from the current image is enough. Record the results in the implementation PR.

- `ssh -o BatchMode=yes` to `127.0.0.1:<port>` as the container user, with the shared key, succeeds. `ssh <alias> herdr --version` prints only the version line.
- `herdr machine add <alias> --label <id> --remote-session default` saves a profile and the machine appears in a local `herdr`.
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
- Extend `dev-entrypoint` with the serve-mode steps above. Leave the existing user, home, Claude settings, and `gosu` path in place for one-shot runs.

CLI, in `cmd/devenv/main.go`:

- Create `~/.devenv/herdr` from `ensureLayout`.
- Generate Herdr keys from `setup` and `run`, next to `ensureSSH`.
- Add worktree resolution, registry load/store, port allocation, and SSH config rendering as pure functions with tests.
- Branch `runContainer`: worktree path ensures the serve container and execs; any other directory keeps `devDockerRunArgs`.
- Extend `down --delete-data` to remove Herdr volumes labeled for this root.
- Update the usage text in `printUsage`.

Docs, in `README.md`:

- `dev` inside a git worktree ensures one long-lived container and attaches to it.
- The container is a Herdr machine. The same worktree keeps the same machine across `devenv down` and the next `dev`.
- Shell exit leaves the container up. `devenv down` stops it and leaves the Herdr profile.
- State layout gains `herdr/` (`id_ed25519`, host key, `worktrees.json`, `ssh_config`, `known_hosts`).
- Directories that are not a worktree stay one-shot.

## Tests

Unit tests in `cmd/devenv/main_test.go`, without Docker:

- Main worktree, linked worktree, submodule, and subdirectory resolution from fixture directories.
- A directory with no `.git` is not a worktree.
- Slug sanitization, length cap, and suffix collision retry.
- The same git directory returns the same id and port. A second worktree gets another id and port.
- A recorded port that is busy is an error, and the stored port is unchanged.
- SSH config contains one shared `Host devenv-*` block and one port block per worktree. The managed include is inserted at the top of an existing `~/.ssh/config` and replaced in place on the next write. Lines outside the block stay.
- Existing keys are left in place when ensure runs again.

The Mac spike covers Docker Desktop, OrbStack, Herdr reconnect, and the single-container rule. Two `dev` processes in the same worktree, one from a subdirectory, share one container. `dev` in a linked worktree of the same repo gets a second container and a second Herdr machine.

## Out of scope

- The Herdr desktop app and `herdr-core`.
- Automatic removal of Herdr profiles.
- Herdr inside one-shot containers for non-worktree directories.
- SSH agent forwarding.
- Publishing port 22 on any address other than `127.0.0.1`.
