package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const (
	registryImage     = "registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e"
	engineDataPath    = "/var/lib/devenv/docker"
	engineLabel       = "com.aduermael.env.devenv.engine"
	engineVersion     = "dind-v1"
	mirrorAddress     = "devenv-mirror:5000"
	buildCacheAddress = "devenv-cache:5000"
)

func cachePrefix(cfg config) string {
	sum := sha256.Sum256([]byte(cfg.Root))
	return fmt.Sprintf("devenv-cache-%x", sum[:8])
}
func cacheNetwork(cfg config) string            { return cachePrefix(cfg) + "-net" }
func engineVolume(cfg config, id string) string { return cachePrefix(cfg) + "-engine-" + id }
func buildCacheRepository(wt worktree) string {
	sum := sha256.Sum256([]byte(wt.CommonDir))
	return fmt.Sprintf("buildcache/repo-%x", sum[:10])
}

// Every daemon exclusively owns one volume. Its managed containerd also lives
// below data-root; no system containerd service is started inside the workspace.
func ensureEngineVolume(ctx context.Context, cfg config, id string) error {
	return ensureDockerVolume(ctx, cfg, engineVolume(cfg, id), "engine-data")
}

func ensureDockerVolume(ctx context.Context, cfg config, name, role string) error {
	out, err := dockerOutput(ctx, "volume", "inspect", name)
	if err == nil {
		var volumes []struct{ Labels map[string]string }
		if err := json.Unmarshal([]byte(out), &volumes); err != nil {
			return err
		}
		if len(volumes) != 1 || !ownedDockerResource(volumes[0].Labels, cfg, role) {
			return fmt.Errorf("volume %s is not owned by this devenv root", name)
		}
		return nil
	}
	if !isDockerNotFound(err) {
		return err
	}
	_, err = dockerOutput(ctx, "volume", "create", "--label", labelManaged+"=true", "--label", labelRoot+"="+cfg.Root, "--label", labelRole+"="+role, name)
	return err
}

func ownedDockerResource(labels map[string]string, cfg config, role string) bool {
	return labels[labelManaged] == "true" && labels[labelRoot] == cfg.Root && labels[labelRole] == role
}

// A pull-through registry cannot accept build-cache pushes. Use independent
// registry services and volumes for downloaded images and writable build cache.
func registryArgs(cfg config, mirror bool) []string {
	role, alias := "build-cache", "devenv-cache"
	if mirror {
		role, alias = "image-mirror", "devenv-mirror"
	}
	name := cachePrefix(cfg) + "-" + role
	args := []string{"run", "-d", "--name", name, "--restart", "unless-stopped",
		"--label", labelManaged + "=true", "--label", labelRoot + "=" + cfg.Root, "--label", labelRole + "=" + role,
		"--network", cacheNetwork(cfg), "--network-alias", alias,
		"--mount", "type=volume,source=" + name + ",target=/var/lib/registry",
		"--health-cmd", "wget -q -O /dev/null http://127.0.0.1:5000/v2/",
		"--health-interval", "2s", "--health-timeout", "2s", "--health-retries", "30",
		"-e", "REGISTRY_HTTP_ADDR=0.0.0.0:5000", "-e", "OTEL_TRACES_EXPORTER=none"}
	if mirror {
		args = append(args, "-e", "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io")
	}
	return append(args, registryImage)
}

func registryMatches(info containerInspect, cfg config, mirror bool) bool {
	alias, role := "devenv-cache", "build-cache"
	if mirror {
		alias, role = "devenv-mirror", "image-mirror"
	}
	if info.Config.Image != registryImage {
		return false
	}
	network, ok := info.NetworkSettings.Networks[cacheNetwork(cfg)]
	if !ok || !slices.Contains(network.Aliases, alias) {
		return false
	}
	if slices.Contains(info.Config.Env, "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io") != mirror {
		return false
	}
	for _, mount := range info.Mounts {
		if mount.Type == "volume" && mount.Name == cachePrefix(cfg)+"-"+role && mount.Destination == "/var/lib/registry" {
			return true
		}
	}
	return false
}

func ensureCacheNetwork(ctx context.Context, cfg config) error {
	out, err := dockerOutput(ctx, "network", "inspect", cacheNetwork(cfg))
	if err == nil {
		var networks []struct{ Labels map[string]string }
		if err := json.Unmarshal([]byte(out), &networks); err != nil {
			return err
		}
		if len(networks) != 1 || !ownedDockerResource(networks[0].Labels, cfg, "docker-cache-network") {
			return fmt.Errorf("network %s is not owned by this devenv root", cacheNetwork(cfg))
		}
		return nil
	}
	if !isDockerNotFound(err) {
		return err
	}
	_, err = dockerOutput(ctx, "network", "create", "--driver", "bridge", "--label", labelManaged+"=true", "--label", labelRoot+"="+cfg.Root, "--label", labelRole+"=docker-cache-network", cacheNetwork(cfg))
	return err
}

func ensureDockerCaches(ctx context.Context, cfg config, stdout io.Writer) error {
	// setup and up can run concurrently, independently of the worktree lock.
	unlock, err := lockFile(filepath.Join(cfg.Root, "run", "docker-caches.lock"))
	if err != nil {
		return err
	}
	defer unlock()
	if err := ensureCacheNetwork(ctx, cfg); err != nil {
		return err
	}
	for _, mirror := range []bool{true, false} {
		role := "build-cache"
		if mirror {
			role = "image-mirror"
		}
		name := cachePrefix(cfg) + "-" + role
		if err := ensureDockerVolume(ctx, cfg, name, role); err != nil {
			return err
		}
		info, exists, err := inspectContainer(ctx, name)
		if err != nil {
			return err
		}
		if exists && !ownedDockerResource(info.Config.Labels, cfg, role) {
			return fmt.Errorf("container %s is not owned by this devenv root", name)
		}
		if exists && !registryMatches(info, cfg, mirror) {
			if err := stopAndRemoveContainer(ctx, name); err != nil {
				return err
			}
			exists = false
		}
		if !exists {
			status(cfg, stdout, "start: shared Docker %s", role)
			if _, err := dockerOutput(ctx, registryArgs(cfg, mirror)...); err != nil {
				return err
			}
		} else if !info.State.Running {
			if _, err := dockerOutput(ctx, "start", name); err != nil {
				return err
			}
		}
		if err := waitForHealthy(ctx, "registry", name, 65*time.Second); err != nil {
			return err
		}
	}
	return nil
}

func waitForHealthy(ctx context.Context, service, name string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	for {
		info, exists, err := inspectContainer(ctx, name)
		if err != nil {
			return err
		}
		if !exists || !info.State.Running {
			return fmt.Errorf("%s %s stopped; inspect docker logs %s", service, name, name)
		}
		if info.State.Health != nil && info.State.Health.Status == "healthy" {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("%s %s not healthy: %w; inspect docker logs %s", service, name, ctx.Err(), name)
		case <-time.After(time.Second):
		}
	}
}

func stopAndRemoveContainer(ctx context.Context, name string) error {
	if _, err := dockerOutput(ctx, "stop", "--time", "45", name); err != nil && !isDockerNotFound(err) {
		return err
	}
	if _, err := dockerOutput(ctx, "rm", name); err != nil && !isDockerNotFound(err) {
		return err
	}
	return nil
}

func removeDockerCacheResources(ctx context.Context, cfg config, deleteData bool) error {
	out, err := dockerOutput(ctx, "network", "inspect", cacheNetwork(cfg))
	if err == nil {
		var networks []struct{ Labels map[string]string }
		if err := json.Unmarshal([]byte(out), &networks); err != nil {
			return err
		}
		if len(networks) != 1 || !ownedDockerResource(networks[0].Labels, cfg, "docker-cache-network") {
			return fmt.Errorf("network %s is not owned by this devenv root", cacheNetwork(cfg))
		}
		if _, err := dockerOutput(ctx, "network", "rm", cacheNetwork(cfg)); err != nil {
			return err
		}
	} else if !isDockerNotFound(err) {
		return err
	}
	if !deleteData {
		return nil
	}
	for _, role := range []string{"engine-data", "image-mirror", "build-cache", daggerEngineRole} {
		out, err := dockerOutput(ctx, "volume", "ls", "-q", "--filter", "label="+labelManaged+"=true", "--filter", "label="+labelRoot+"="+cfg.Root, "--filter", "label="+labelRole+"="+role)
		if err != nil {
			return err
		}
		if names := strings.Fields(out); len(names) > 0 {
			if _, err := dockerOutput(ctx, append([]string{"volume", "rm"}, names...)...); err != nil {
				return err
			}
		}
	}
	return nil
}

// Old proxy containers may still serve older running workspaces. New workspaces
// neither join that network nor mount the directory containing its Unix socket.
func engineEnvironment(wt worktree, rec worktreeRecord) []string {
	return []string{"DOCKER_HOST=unix:///var/run/docker.sock", "DEVENV_DOCKER_ID=" + rec.ID,
		"DEVENV_DOCKER_MIRROR=http://" + mirrorAddress, "DEVENV_BUILD_CACHE_REGISTRY=" + buildCacheAddress,
		"DEVENV_BUILD_CACHE_REPO=" + buildCacheRepository(wt), "BUILDX_CONFIG=/run/devenv/buildx", "BUILDX_BUILDER=default"}
}

// The image must run its own Docker engine and name the Dagger release it
// installs: the shared Dagger engine runs that same release.
func requireEngineImage(ctx context.Context, cfg config) (string, error) {
	out, err := dockerOutput(ctx, "image", "inspect", cfg.Image, "--format", "{{json .Config.Labels}}")
	if err != nil {
		return "", err
	}
	var labels map[string]string
	if err := json.Unmarshal([]byte(out), &labels); err != nil {
		return "", fmt.Errorf("parse labels of image %s: %w", cfg.Image, err)
	}
	if labels[engineLabel] != engineVersion {
		return "", fmt.Errorf("image %s predates nested Docker; rebuild it with devenv setup", cfg.Image)
	}
	version := labels[daggerLabel]
	if !daggerVersionPattern.MatchString(version) {
		return "", fmt.Errorf("image %s does not name the Dagger release for the shared engine (label %s=%q); rebuild it with devenv setup", cfg.Image, daggerLabel, version)
	}
	return version, nil
}
