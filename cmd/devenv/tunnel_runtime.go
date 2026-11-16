// The host CLI manages a cloudflared sidecar on each workspace's ingress network.
// Only the sidecar mounts the private runtime token; workspace metadata is public.
package main

import (
	"context"
	"encoding/csv"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

const tunnelImage = "cloudflare/cloudflared:2026.11.0"
const tunnelTokenPath = "/run/devenv-tunnel-token"

func requireLocalDocker(ctx context.Context) error {
	endpoint := os.Getenv("DOCKER_HOST")
	contextName := os.Getenv("DOCKER_CONTEXT")
	if endpoint == "" || contextName != "" {
		args := []string{"context", "inspect"}
		if contextName != "" {
			args = append(args, contextName)
		}
		args = append(args, "--format", `{{(index .Endpoints "docker").Host}}`)
		out, err := dockerOutput(ctx, args...)
		if err != nil {
			return err
		}
		endpoint = strings.TrimSpace(out)
	}
	if !strings.HasPrefix(endpoint, "unix://") {
		return errors.New("tunnel token mounts require the host's local Docker Unix-socket context")
	}
	return nil
}
func ownsTunnelContainer(info containerInspect, s tunnelState) bool {
	l := info.Config.Labels
	return l[labelManaged] == "true" && l[labelRole] == "tunnel" && l[tunnelInstanceLabel] == s.ID && l[labelWorktreeGitDir] == s.GitDir && l[labelRoot] == s.Root
}
func (s tunnelState) checkRuntimeUpgrade() error {
	if len(s.LegacyProcess) > 0 && string(s.LegacyProcess) != "null" {
		return errors.New("stop this tunnel with the previous native-runtime version of devenv before upgrading")
	}
	return nil
}
func stopTunnelRuntime(ctx context.Context, s tunnelState) error {
	if err := s.checkRuntimeUpgrade(); err != nil {
		return err
	}
	if s.ID == "" {
		return nil
	}
	info, exists, err := inspectContainer(ctx, s.container())
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	if !ownsTunnelContainer(info, s) {
		return errors.New("tunnel container belongs to another allocation; refusing removal")
	}
	_, err = dockerOutput(ctx, "rm", "-f", s.container())
	return err
}
func ensureTunnelNetwork(ctx context.Context, s tunnelState) error {
	out, err := dockerOutput(ctx, "network", "inspect", s.network(), "--format", `{{.Driver}} {{.Internal}} {{index .Labels "io.devenv.instance"}} {{index .Labels "com.aduermael.env.devenv.worktree-gitdir"}}`)
	if err != nil {
		if !isDockerNotFound(err) {
			return err
		}
		_, err = dockerOutput(ctx, "network", "create", "--driver", "bridge", "--label", labelManaged+"=true", "--label", labelRole+"=ingress", "--label", labelRoot+"="+s.Root, "--label", labelWorktreeGitDir+"="+s.GitDir, "--label", tunnelInstanceLabel+"="+s.ID, s.network())
		if err != nil {
			return err
		}
		out, err = dockerOutput(ctx, "network", "inspect", s.network(), "--format", `{{.Driver}} {{.Internal}} {{index .Labels "io.devenv.instance"}} {{index .Labels "com.aduermael.env.devenv.worktree-gitdir"}}`)
	}
	if err != nil {
		return err
	}
	if strings.TrimSpace(out) != "bridge false "+s.ID+" "+s.GitDir {
		return errors.New("ingress network ownership or isolation does not match this worktree")
	}
	return nil
}
func tunnelArgs(s tunnelState, path string) []string {
	token := filepath.Join(filepath.Dir(path), "runtime-token")
	var mount strings.Builder
	w := csv.NewWriter(&mount)
	_ = w.Write([]string{"type=bind", "source=" + token, "target=" + tunnelTokenPath, "readonly"})
	w.Flush()
	return []string{"run", "-d", "--name", s.container(), "--restart", "unless-stopped", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--user", fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()), "--label", labelManaged + "=true", "--label", labelRole + "=tunnel", "--label", labelRoot + "=" + s.Root, "--label", labelWorktreeGitDir + "=" + s.GitDir, "--label", tunnelInstanceLabel + "=" + s.ID, "--network", s.network(), "--mount", strings.TrimSuffix(mount.String(), "\n"), tunnelImage, "tunnel", "--no-autoupdate", "run", "--token-file", tunnelTokenPath}
}
func startTunnelRuntime(ctx context.Context, s *tunnelState, path string, api cloudflareAPI) error {
	if err := s.checkRuntimeUpgrade(); err != nil {
		return err
	}
	if err := ensureTunnelNetwork(ctx, *s); err != nil {
		return err
	}
	info, exists, err := inspectContainer(ctx, s.container())
	if err != nil {
		return err
	}
	if exists && !ownsTunnelContainer(info, *s) {
		return errors.New("tunnel container belongs to another allocation")
	}
	if err := api.route(ctx, *s); err != nil {
		return err
	}
	if exists && info.State.Running && info.Config.Image == tunnelImage {
		return nil
	}
	if err = stopTunnelRuntime(ctx, *s); err != nil {
		return err
	}
	if _, err = dockerOutput(ctx, tunnelArgs(*s, path)...); err != nil {
		return err
	}
	info, exists, err = inspectContainer(ctx, s.container())
	if err != nil {
		return err
	}
	if !exists || !info.State.Running {
		return fmt.Errorf("tunnel container did not stay running; inspect docker logs %s", s.container())
	}
	return nil
}
func workspaceTunnelMatches(info containerInspect, s *tunnelState) bool {
	if s == nil {
		for _, item := range info.Config.Env {
			if strings.HasPrefix(item, "DEVENV_INSTANCE_ID=") {
				return false
			}
		}
		return true
	}
	for _, item := range s.environment() {
		if !slices.Contains(info.Config.Env, item) {
			return false
		}
	}
	network, ok := info.NetworkSettings.Networks[s.network()]
	return ok && slices.Contains(network.Aliases, "workspace")
}
func prepareTunnel(ctx context.Context, cfg config, wt worktree) (*tunnelState, error) {
	state, path, err := loadTunnel(wt)
	if err != nil {
		return nil, err
	}
	if state != nil && state.Root != cfg.Root {
		return nil, errors.New("this worktree's tunnel belongs to a different devenv root; reuse its original --root")
	}
	if state != nil {
		if err = state.checkRuntimeUpgrade(); err != nil {
			return nil, err
		}
	}
	enabled := state != nil && state.Enabled && !state.Retired
	if cfg.TunnelSet {
		enabled = cfg.Tunnel
	}
	_, info, running, err := findWorktreeContainer(ctx, cfg, wt)
	if err != nil {
		return nil, err
	}
	if running && info.State.Running {
		for _, mount := range info.Mounts {
			if mount.Destination == containerWorkspace && mount.Source != wt.RepoRoot {
				return nil, errors.New("worktree moved while its workspace was running; stop it before restarting at the new path")
			}
		}
	}
	desired := state
	if !enabled {
		desired = nil
	}
	if running && info.State.Running && (!workspaceTunnelMatches(info, desired) || (enabled && (state == nil || state.Retired))) {
		return nil, errors.New("stop this worktree before changing its tunnel configuration: devenv stop, then devenv up --tunnel (or --tunnel=false)")
	}
	if !enabled {
		if state != nil {
			if err = stopTunnelRuntime(ctx, *state); err != nil {
				return nil, err
			}
			state.Enabled = false
			if err = writePrivateJSON(path, state); err != nil {
				return nil, err
			}
		}
		return nil, nil
	}
	settings, err := loadTunnelSettings()
	if err != nil {
		return nil, fmt.Errorf("configure host ingress first with devenv tunnel configure: %w", err)
	}
	if err = validateTunnelSettings(settings); err != nil {
		return nil, err
	}
	if err = validateTunnelPaths(cfg, &wt, &settings); err != nil {
		return nil, err
	}
	if err = validateManagedTunnelPaths(ctx, settings); err != nil {
		return nil, err
	}
	if err = requireLocalDocker(ctx); err != nil {
		return nil, err
	}
	api, err := tunnelAPI(settings)
	if err != nil {
		return nil, err
	}
	if state == nil || state.Retired {
		if state != nil {
			if err = removeTunnelToken(path); err != nil {
				return nil, err
			}
		}
		suffix, err := randomSuffix(32)
		if err != nil {
			return nil, err
		}
		state = &tunnelState{GitDir: wt.GitDir, Root: cfg.Root, Checkout: wt.CheckoutPath, Name: "devenv-" + suffix, AccountID: settings.AccountID, ZoneID: settings.ZoneID, Domain: settings.Domain, Origin: settings.Origin, DNSRecords: map[string]string{}}
	}
	if state.AccountID != settings.AccountID || state.ZoneID != settings.ZoneID || state.Domain != settings.Domain {
		return nil, errors.New("host account, zone or domain differs from this binding; restore its host settings or retire it before changing these properties")
	}
	state.Enabled = true
	state.Checkout = wt.CheckoutPath
	if err = writePrivateJSON(path, state); err != nil {
		return nil, err
	}
	if err = api.allocate(ctx, state, path); err != nil {
		return nil, err
	}
	if err = startTunnelRuntime(ctx, state, path, api); err != nil {
		return nil, err
	}
	return state, nil
}
func stopWorktreeTunnel(ctx context.Context, cfg config, wt worktree) error {
	state, path, err := loadTunnel(wt)
	if err != nil || state == nil {
		return err
	}
	if state.Root != cfg.Root {
		return errors.New("this worktree's tunnel belongs to a different devenv root; reuse its original --root")
	}
	if err = stopTunnelRuntime(ctx, *state); err != nil {
		return err
	}
	return writePrivateJSON(path, state)
}
func stopRootTunnels(ctx context.Context, cfg config) error {
	home, err := tunnelHome()
	if err != nil {
		return err
	}
	paths, err := filepath.Glob(filepath.Join(home, "instances", "*", "state.json"))
	if err != nil {
		return err
	}
	for _, path := range paths {
		var state tunnelState
		if err = readJSON(path, &state); err != nil {
			return err
		}
		if state.Root != cfg.Root {
			continue
		}
		if err = stopTunnelRuntime(ctx, state); err != nil {
			return err
		}
		if err = writePrivateJSON(path, state); err != nil {
			return err
		}
	}
	return nil
}
func validateConfiguredTunnelPaths(cfg config, wt *worktree) error {
	settings, err := loadTunnelSettings()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return validateTunnelPaths(cfg, wt, &settings)
}
