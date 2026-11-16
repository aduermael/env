// Native cloudflared keeps bearer credentials outside workspace mounts.
// A credential-free relay publishes only on host loopback and joins
// one dedicated ingress network. Process identity checks protect against PID reuse.
package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

const tunnelRelayImage = "alpine/socat:1.8.0.3"

type tunnelProcess struct {
	PID      int    `json:"pid"`
	Identity string `json:"identity"`
}

func nativeCloudflared(settings tunnelSettings) (string, error) {
	binary := settings.Cloudflared
	if binary == "" {
		binary = "cloudflared"
	}
	path, err := exec.LookPath(binary)
	if err != nil {
		return "", errors.New("native cloudflared 2025.4.0 or newer is required; install it on the host (brew install cloudflared), or configure --cloudflared")
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return "", err
	}
	output, err := exec.Command(path, "--version").Output()
	if err != nil {
		return "", fmt.Errorf("check native cloudflared version: %w", err)
	}
	for _, field := range strings.Fields(string(output)) {
		var year, month, patch int
		if _, err := fmt.Sscanf(field, "%d.%d.%d", &year, &month, &patch); err == nil && (year > 2025 || year == 2025 && month >= 4) {
			return path, nil
		}
	}
	return "", errors.New("cloudflared 2025.4.0 or newer is required for host-only --token-file")
}
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
		return errors.New("native tunnels require a local Docker Desktop Unix-socket context; remote Docker endpoints cannot use the host loopback relay")
	}
	return nil
}
func processIdentity(pid int) (string, error) {
	if pid < 2 {
		return "", errors.New("invalid tunnel process ID")
	}
	output, err := exec.Command("ps", "-ww", "-p", strconv.Itoa(pid), "-o", "lstart=", "-o", "command=").Output()
	return strings.TrimSpace(string(output)), err
}
func tunnelProcessRunning(p *tunnelProcess) bool {
	if p == nil || p.Identity == "" {
		return false
	}
	actual, err := processIdentity(p.PID)
	return err == nil && actual == p.Identity
}
func stopTunnelProcess(p *tunnelProcess) error {
	if !tunnelProcessRunning(p) {
		return nil
	}
	process, err := os.FindProcess(p.PID)
	if err != nil {
		return err
	}
	if err = process.Signal(os.Interrupt); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if !tunnelProcessRunning(p) {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	if tunnelProcessRunning(p) {
		if err = process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return err
		}
		deadline = time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if !tunnelProcessRunning(p) {
				return nil
			}
			time.Sleep(25 * time.Millisecond)
		}
		return errors.New("native cloudflared has not exited; retaining relay to prevent stale port reuse")
	}
	return nil
}
func stopTunnelRuntime(ctx context.Context, s tunnelState, path string) error {
	if err := stopTunnelProcess(s.Process); err != nil {
		return err
	}
	if err := recoverTunnelProcesses(s, path); err != nil {
		return err
	}
	if s.ID == "" {
		return nil
	}
	info, exists, err := inspectContainer(ctx, s.relay())
	if err != nil {
		return err
	}
	if exists {
		if !ownsTunnelContainer(info, s) {
			return errors.New("ingress relay belongs to another allocation; refusing removal")
		}
		if _, err = dockerOutput(ctx, "rm", "-f", s.relay()); err != nil {
			return err
		}
	}
	return nil
}

// Recover a process started immediately before a CLI crash, before its PID was
// saved. The exact executable and private token path identify only this binding.
func recoverTunnelProcesses(s tunnelState, path string) error {
	if s.Binary == "" {
		return nil
	}
	output, err := exec.Command("ps", "-ww", "-axo", "pid=,command=").Output()
	if err != nil {
		return err
	}
	want := s.Binary + " tunnel --no-autoupdate run --token-file " + filepath.Join(filepath.Dir(path), "runtime-token")
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		pidText, command, ok := strings.Cut(line, " ")
		if !ok || strings.TrimSpace(command) != want {
			continue
		}
		pid, err := strconv.Atoi(pidText)
		if err != nil {
			return err
		}
		identity, err := processIdentity(pid)
		if err != nil {
			continue
		}
		if err := stopTunnelProcess(&tunnelProcess{PID: pid, Identity: identity}); err != nil {
			return err
		}
	}
	return nil
}
func ownsTunnelContainer(info containerInspect, s tunnelState) bool {
	l := info.Config.Labels
	return l[labelManaged] == "true" && l[labelRole] == "tunnel-relay" && l[tunnelInstanceLabel] == s.ID && l[labelWorktreeGitDir] == s.GitDir && l[labelRoot] == s.Root
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
func relayArgs(s tunnelState) []string {
	u, _ := url.Parse(s.Origin)
	return []string{"run", "-d", "--name", s.relay(), "--restart", "unless-stopped", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--user", "65534:65534", "--label", labelManaged + "=true", "--label", labelRole + "=tunnel-relay", "--label", labelRoot + "=" + s.Root, "--label", labelWorktreeGitDir + "=" + s.GitDir, "--label", tunnelInstanceLabel + "=" + s.ID, "--network", s.network(), "-p", "127.0.0.1::8080", tunnelRelayImage, "TCP-LISTEN:8080,fork,reuseaddr", "TCP:" + u.Hostname() + ":" + u.Port()}
}
func relayPort(info containerInspect) (string, error) {
	bindings := info.NetworkSettings.Ports["8080/tcp"]
	if len(bindings) != 1 || bindings[0].HostIP != "127.0.0.1" {
		return "", errors.New("ingress relay must publish exactly one loopback port")
	}
	n, err := strconv.Atoi(bindings[0].HostPort)
	if err != nil || n < 1 || n > 65535 {
		return "", errors.New("invalid ingress relay port")
	}
	return bindings[0].HostPort, nil
}
func startTunnelRuntime(ctx context.Context, s *tunnelState, path, binary string, api cloudflareAPI) error {
	if err := ensureTunnelNetwork(ctx, *s); err != nil {
		return err
	}
	info, exists, err := inspectContainer(ctx, s.relay())
	if err != nil {
		return err
	}
	if exists && !ownsTunnelContainer(info, *s) {
		return errors.New("ingress relay name is already owned by another worktree")
	}
	if exists && info.State.Running && tunnelProcessRunning(s.Process) {
		_, err = relayPort(info)
		return err
	}
	if err = stopTunnelRuntime(ctx, *s, path); err != nil {
		return err
	}
	s.Process = nil
	s.Binary = binary
	if err = writePrivateJSON(path, s); err != nil {
		return err
	}
	if _, err = dockerOutput(ctx, relayArgs(*s)...); err != nil {
		return err
	}
	info, exists, err = inspectContainer(ctx, s.relay())
	if err != nil {
		return err
	}
	if !exists {
		return errors.New("ingress relay did not start")
	}
	port, err := relayPort(info)
	if err != nil {
		return err
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 5*time.Second)
	if err != nil {
		return fmt.Errorf("local relay unavailable: %w", err)
	}
	conn.Close()
	if err = api.route(ctx, *s, port); err != nil {
		return err
	}
	tokenPath := filepath.Join(filepath.Dir(path), "runtime-token")
	log, err := os.OpenFile(filepath.Join(filepath.Dir(path), "cloudflared.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := exec.Command(binary, "tunnel", "--no-autoupdate", "run", "--token-file", tokenPath)
	cmd.Stdout = log
	cmd.Stderr = log
	detachCommand(cmd)
	if err = cmd.Start(); err != nil {
		return err
	}
	identity, err := processIdentity(cmd.Process.Pid)
	if err != nil || !strings.Contains(identity, tokenPath) {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return errors.New("native cloudflared exited before its ownership could be recorded; inspect private cloudflared.log")
	}
	s.Process = &tunnelProcess{PID: cmd.Process.Pid, Identity: identity}
	if err = writePrivateJSON(path, s); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	_ = cmd.Process.Release()
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
			if err = stopTunnelRuntime(ctx, *state, path); err != nil {
				return nil, err
			}
			state.Enabled = false
			state.Process = nil
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
	binary, err := nativeCloudflared(settings)
	if err != nil {
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
	if err = startTunnelRuntime(ctx, state, path, binary, api); err != nil {
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
	if err = stopTunnelRuntime(ctx, *state, path); err != nil {
		return err
	}
	state.Process = nil
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
		if err = stopTunnelRuntime(ctx, state, path); err != nil {
			return err
		}
		state.Process = nil
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
