// One Dagger engine serves every workspace of a devenv root. Workspaces keep
// their private Docker daemon; only the Dagger runner is shared, so its
// BuildKit cache, module cache and cache volumes are downloaded once.
//
// Sharing removes isolation between worktrees: cached layers and named cache
// volumes are visible to all of them, and an engine restart or a full disk
// stops Dagger everywhere at once.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	// The workspace image names the Dagger CLI release it installs. The image
	// chooses only the version: the engine repository is fixed here.
	daggerLabel     = "com.aduermael.env.devenv.dagger"
	daggerSpecLabel = "com.aduermael.env.devenv.dagger-spec"
	// A workspace records the engine release devenv pointed it at. The key
	// differs from the image's label, which every container inherits.
	daggerWorkspaceLabel   = "com.aduermael.env.devenv.shared-dagger"
	daggerEngineRepository = "registry.dagger.io/engine"
	daggerEngineRole       = "dagger-engine"
	daggerEngineAlias      = "devenv-dagger"
	daggerEnginePort       = "1234"
	daggerStatePath        = "/var/lib/dagger"
	daggerConfigPath       = "/etc/dagger/engine.json"
	daggerReadyTimeout     = 3 * time.Minute
)

// Exactly three numeric parts keep the alias below unambiguous. The CLI reads
// DAGGER_ENGINE from v1 on; an older one would ignore the shared engine and
// start its own.
var daggerVersionPattern = regexp.MustCompile(`^v([1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9a-z]+(\.[0-9a-z]+)*)?$`)

func daggerEngineImage(version string) string { return daggerEngineRepository + ":" + version }
func daggerEngineName(cfg config) string      { return cachePrefix(cfg) + "-" + daggerEngineRole }

// The address carries the release, so a CLI can only resolve an engine of its
// own release. A workspace whose CLI no longer matches fails to resolve it
// instead of working against another release, which Dagger itself allows.
func daggerEngineHost(version string) string {
	return daggerEngineAlias + "-" + strings.ReplaceAll(version, ".", "-")
}

func daggerEngineAddress(version string) string {
	return "tcp://" + daggerEngineHost(version) + ":" + daggerEnginePort
}

// container:// engines are out of reach: every workspace has its own Docker
// socket. The entrypoint hands these values to each session and to the dagger
// wrapper.
func daggerEnvironment(version string) []string {
	return []string{"DAGGER_ENGINE=" + daggerEngineAddress(version), "DEVENV_DAGGER_ENGINE_IMAGE=" + daggerEngineImage(version)}
}

// Docker Hub pulls go through the root's mirror, as for workspace daemons.
// The mirror speaks plain HTTP. When it is down or lacks an image, BuildKit
// moves on to Docker Hub itself; other registries are not mirrored.
func daggerEngineConfig() []byte {
	data, _ := json.Marshal(map[string]map[string]map[string]any{"registries": {
		"docker.io":   {"mirrors": []string{mirrorAddress}},
		mirrorAddress: {"http": true},
	}})
	return data
}

func daggerConfigFile(cfg config) string { return filepath.Join(cfg.Root, "dagger-engine.json") }

// The engine runs as Dagger starts its own: privileged, always restarted, its
// state on one volume. That volume belongs to this single container; two
// engines on one state directory corrupt it. tcp:// has no authentication, so
// the port is not published: it is reachable from the root's cache network,
// which includes containers started inside a workspace. The spec covers the
// engine's configuration too: its file keeps one path whatever it holds.
func daggerEngineArgs(cfg config, version string, engineConfig []byte) []string {
	name := daggerEngineName(cfg)
	options := []string{"run", "-d", "--name", name, "--restart", "always", "--privileged",
		"--label", labelManaged + "=true", "--label", labelRoot + "=" + cfg.Root, "--label", labelRole + "=" + daggerEngineRole,
		"--label", daggerLabel + "=" + version,
		"--network", cacheNetwork(cfg), "--network-alias", daggerEngineAlias, "--network-alias", daggerEngineHost(version),
		"--mount", "type=volume,source=" + name + ",target=" + daggerStatePath,
		"--mount", "type=bind,source=" + daggerConfigFile(cfg) + ",target=" + daggerConfigPath + ",readonly",
		"--health-cmd", "buildctl dial-stdio --timeout 2",
		"--health-interval", "5s", "--health-timeout", "5s", "--health-retries", "6", "--health-start-period", "60s"}
	command := []string{daggerEngineImage(version),
		"--addr", "unix:///run/dagger/engine.sock", "--addr", "tcp://0.0.0.0:" + daggerEnginePort}
	spec := sha256.Sum256([]byte(strings.Join(append(append(append([]string{}, options...), command...), string(engineConfig)), "\x00")))
	options = append(options, "--label", fmt.Sprintf("%s=%x", daggerSpecLabel, spec[:8]))
	return append(options, command...)
}

func daggerSpec(args []string) string {
	for i, arg := range args {
		if value, ok := strings.CutPrefix(arg, daggerSpecLabel+"="); ok && i > 0 && args[i-1] == "--label" {
			return value
		}
	}
	return ""
}

// setup moves the engine to the image's release. up only creates or starts
// it: replacing a running engine ends every session on it, so two images with
// different releases must not take it from each other on each up.
func ensureDaggerEngine(ctx context.Context, cfg config, replace bool, stdout, stderr io.Writer) error {
	version := cfg.DaggerVersion
	if !daggerVersionPattern.MatchString(version) {
		return fmt.Errorf("unsupported Dagger release %q", version)
	}
	unlock, err := lockFile(filepath.Join(cfg.Root, "run", "docker-caches.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	if err := ensureCacheNetwork(ctx, cfg); err != nil {
		return err
	}
	name := daggerEngineName(cfg)
	if err := ensureDockerVolume(ctx, cfg, name, daggerEngineRole); err != nil {
		return err
	}
	engineConfig := daggerEngineConfig()
	args := daggerEngineArgs(cfg, version, engineConfig)
	info, exists, err := inspectContainer(ctx, name)
	if err != nil {
		return err
	}
	if exists && !ownedDockerResource(info.Config.Labels, cfg, daggerEngineRole) {
		return fmt.Errorf("container %s is not owned by this devenv root", name)
	}
	running := info.Config.Labels[daggerLabel]
	current := exists && info.Config.Labels[daggerSpecLabel] == daggerSpec(args)
	if exists && !current && !replace && running != version {
		notice(stderr, "the shared Dagger engine runs %s, but image %s installs Dagger %s; dagger stops with an error in workspaces of this image", daggerEngineImage(running), cfg.Image, version)
		notice(stderr, "move the engine with: devenv setup --skip-build (workspaces on %s must then be recreated)", running)
		return nil
	}
	if exists && !current && !replace {
		notice(stderr, "the shared Dagger engine %s keeps the settings it started with until: devenv setup --skip-build (it restarts the engine, ending running dagger sessions; the cache stays and workspaces need not be recreated)", daggerEngineImage(running))
	}
	// Fetch the image while the old engine still serves: a failed download
	// must not leave the machine without an engine.
	if !exists || !current {
		if err := pullIfMissing(ctx, cfg, daggerEngineImage(version), stdout, stderr); err != nil {
			return err
		}
	}
	if exists && !current && replace {
		status(cfg, stdout, "replace: shared Dagger engine %s", daggerEngineImage(running))
		// The old engine has exited before the new one opens the volume.
		if err := stopAndRemoveContainer(ctx, name); err != nil {
			return err
		}
		exists = false
	}
	// A stopped engine needs the file to start again, so it is written on
	// every run. An engine that is already running read it when it started.
	if err := os.WriteFile(daggerConfigFile(cfg), engineConfig, 0o644); err != nil {
		return fmt.Errorf("write Dagger engine configuration: %w", err)
	}
	if !exists {
		status(cfg, stdout, "start: shared Dagger engine %s", daggerEngineImage(version))
		if _, err := dockerOutput(ctx, args...); err != nil {
			return fmt.Errorf("start shared Dagger engine: %w", err)
		}
	} else if !info.State.Running {
		if _, err := dockerOutput(ctx, "start", name); err != nil {
			return err
		}
	}
	if err := waitForHealthy(ctx, "Dagger engine", name, daggerReadyTimeout); err != nil {
		return err
	}
	if !replace {
		return nil
	}
	stale, err := staleDaggerWorkspaces(ctx, cfg, version)
	if err != nil {
		return err
	}
	if len(stale) > 0 {
		notice(stderr, "these running workspaces predate the shared Dagger engine %s; recreate each with devenv down, then devenv up: %s", daggerEngineImage(version), strings.Join(stale, ", "))
	}
	return nil
}

func pullIfMissing(ctx context.Context, cfg config, image string, stdout, stderr io.Writer) error {
	if _, err := dockerOutput(ctx, "image", "inspect", image, "--format", "{{.Id}}"); err == nil {
		return nil
	}
	status(cfg, stdout, "pull: %s", image)
	if err := dockerRun(ctx, stdoutFor(cfg, stdout), stderrFor(cfg, stderr), "pull", image); err != nil {
		return fmt.Errorf("pull %s: %w", image, err)
	}
	return nil
}

// Running workspaces keep the image they started with. One with another
// Dagger release gets an error from its dagger wrapper; one from before the
// shared engine still starts a private engine.
func staleDaggerWorkspaces(ctx context.Context, cfg config, version string) ([]string, error) {
	out, err := dockerOutput(ctx, "ps",
		"--filter", "label="+labelManaged+"=true", "--filter", "label="+labelRole+"=workspace", "--filter", "label="+labelRoot+"="+cfg.Root,
		"--format", `{{.Names}} {{.Label "`+daggerWorkspaceLabel+`"}}`)
	if err != nil {
		return nil, fmt.Errorf("list workspaces: %w", err)
	}
	var stale []string
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && (len(fields) < 2 || fields[1] != version) {
			stale = append(stale, fields[0])
		}
	}
	return stale, nil
}
