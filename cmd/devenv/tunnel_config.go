// Optional public ingress belongs to the host. Only non-secret instance metadata
// enters a workspace; Cloudflare settings, runtime tokens and process records
// live outside every directory that devenv mounts into workspaces.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const tunnelInstanceLabel = "io.devenv.instance"

var tunnelUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var cloudflareID = regexp.MustCompile(`^[0-9a-f]{32}$`)
var tunnelDomain = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$`)
var tunnelAlias = regexp.MustCompile(`^[a-z][a-z0-9-]{0,62}$`)

type tunnelSettings struct {
	AccountID   string `json:"account_id"`
	ZoneID      string `json:"zone_id"`
	Domain      string `json:"domain"`
	TokenFile   string `json:"api_token_file"`
	Origin      string `json:"origin"`
	Cloudflared string `json:"cloudflared"`
}

type tunnelState struct {
	GitDir     string            `json:"git_dir"`
	Root       string            `json:"root"`
	Checkout   string            `json:"checkout"`
	Enabled    bool              `json:"enabled"`
	Retired    bool              `json:"retired,omitempty"`
	Name       string            `json:"allocation_name"`
	AccountID  string            `json:"account_id"`
	ZoneID     string            `json:"zone_id"`
	Domain     string            `json:"domain"`
	Origin     string            `json:"origin"`
	ID         string            `json:"instance_id"`
	DNSRecords map[string]string `json:"dns_records"`
	Process    *tunnelProcess    `json:"process,omitempty"`
	Binary     string            `json:"runtime_binary,omitempty"`
}

func (s tunnelState) network() string   { return "devenv-ingress-" + s.ID }
func (s tunnelState) relay() string     { return "devenv-ingress-relay-" + s.ID }
func (s tunnelState) appHost() string   { return s.ID + "." + s.Domain }
func (s tunnelState) filesHost() string { return "files-" + s.ID + "." + s.Domain }
func (s tunnelState) environment() []string {
	return []string{"DEVENV_INSTANCE_ID=" + s.ID, "DEVENV_PUBLIC_URL=https://" + s.appHost(), "DEVENV_FILES_URL=https://" + s.filesHost(), "DEVENV_INGRESS_NETWORK=" + s.network()}
}

func tunnelHome() (string, error) {
	root := os.Getenv("DEVENV_TUNNEL_HOME")
	if root == "" {
		base, err := os.UserConfigDir()
		if err != nil {
			return "", err
		}
		root = filepath.Join(base, "devenv-tunnels")
	}
	return canonicalFuturePath(root)
}

// Resolve existing ancestors too, so symlinks cannot hide a future secret path.
func canonicalFuturePath(path string) (string, error) {
	abs, err := expandAndAbs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err == nil {
		return resolved, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	parent := filepath.Dir(abs)
	if parent == abs {
		return "", err
	}
	resolved, err = canonicalFuturePath(parent)
	if err != nil {
		return "", err
	}
	return filepath.Join(resolved, filepath.Base(abs)), nil
}

func pathsOverlap(a, b string) bool { return a == b || isUnder(a, b) || isUnder(b, a) }
func validateTunnelPaths(cfg config, wt *worktree, settings *tunnelSettings) error {
	home, err := tunnelHome()
	if err != nil {
		return err
	}
	protected := []string{home}
	if settings != nil && settings.TokenFile != "" {
		p, err := canonicalFuturePath(settings.TokenFile)
		if err != nil {
			return err
		}
		protected = append(protected, p)
	}
	roots := []string{cfg.Root}
	if wt != nil {
		roots = append(roots, wt.RepoRoot)
	}
	reg, err := loadRegistry(registryPath(cfg))
	if err != nil {
		return err
	}
	for _, record := range reg.Worktrees {
		roots = append(roots, filepath.Dir(record.GitCommonDir))
	}
	return validateProtectedRoots(protected, roots)
}

func validateProtectedRoots(protected, roots []string) error {
	for _, root := range roots {
		root, err := canonicalFuturePath(root)
		if err != nil {
			return err
		}
		for _, secret := range protected {
			if pathsOverlap(root, secret) {
				return fmt.Errorf("host tunnel state and credentials must be outside workspace mounts: %s overlaps %s", secret, root)
			}
		}
	}
	return nil
}

func validateManagedTunnelPaths(ctx context.Context, settings tunnelSettings) error {
	home, err := tunnelHome()
	if err != nil {
		return err
	}
	out, err := dockerOutput(ctx, "ps", "-aq", "--filter", "label="+labelManaged+"=true", "--filter", "label="+labelRole+"=workspace")
	if err != nil {
		return fmt.Errorf("inspect mounted workspace roots before using host credentials: %w", err)
	}
	var roots []string
	for _, id := range strings.Fields(out) {
		info, exists, err := inspectContainer(ctx, id)
		if err != nil {
			return err
		}
		if exists {
			for _, mount := range info.Mounts {
				if mount.Type == "bind" {
					roots = append(roots, mount.Source)
				}
			}
		}
	}
	return validateProtectedRoots([]string{home, settings.TokenFile}, roots)
}

func lockTunnels() (func(), error) {
	home, err := tunnelHome()
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(home, 0700); err != nil {
		return nil, err
	}
	if err = os.Chmod(home, 0700); err != nil {
		return nil, err
	}
	return lockFile(filepath.Join(home, "tunnels.lock"))
}

func tunnelStatePath(wt worktree) (string, error) {
	home, err := tunnelHome()
	if err != nil {
		return "", err
	}
	key := sha256.Sum256([]byte(wt.GitDir))
	return filepath.Join(home, "instances", hex.EncodeToString(key[:]), "state.json"), nil
}
func readJSON(path string, out any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, out)
}
func writePrivateJSON(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return writePrivate(path, append(data, '\n'))
}
func writePrivate(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".pending-")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}
func loadTunnelSettings() (tunnelSettings, error) {
	home, err := tunnelHome()
	if err != nil {
		return tunnelSettings{}, err
	}
	var settings tunnelSettings
	err = readJSON(filepath.Join(home, "config.json"), &settings)
	return settings, err
}
func loadTunnel(wt worktree) (*tunnelState, string, error) {
	path, err := tunnelStatePath(wt)
	if err != nil {
		return nil, "", err
	}
	var state tunnelState
	err = readJSON(path, &state)
	if errors.Is(err, os.ErrNotExist) {
		return nil, path, nil
	}
	if err != nil {
		return nil, path, err
	}
	if state.GitDir != wt.GitDir || (state.ID != "" && !tunnelUUID.MatchString(state.ID)) {
		return nil, path, fmt.Errorf("invalid tunnel binding in %s", path)
	}
	if state.DNSRecords == nil {
		state.DNSRecords = map[string]string{}
	}
	return &state, path, nil
}
func validateTunnelSettings(s tunnelSettings) error {
	if !cloudflareID.MatchString(s.AccountID) || !cloudflareID.MatchString(s.ZoneID) {
		return errors.New("Cloudflare account and zone IDs must contain 32 lowercase hexadecimal characters")
	}
	if !tunnelDomain.MatchString(s.Domain) || len(s.Domain) > 210 {
		return errors.New("domain must be the canonical Cloudflare zone; first-level hosts use free Universal SSL")
	}
	u, err := url.Parse(s.Origin)
	if err != nil || u.Scheme != "http" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" || !tunnelAlias.MatchString(u.Hostname()) {
		return errors.New("origin must be http://<Docker-network-alias>:<port>, without a path")
	}
	_, port, err := net.SplitHostPort(u.Host)
	if err != nil {
		return errors.New("origin requires one explicit HTTP port")
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return errors.New("invalid origin port")
	}
	if s.TokenFile == "" {
		return errors.New("--api-token-file is required")
	}
	return nil
}
func tunnelAPI(settings tunnelSettings) (cloudflareAPI, error) {
	info, err := os.Stat(settings.TokenFile)
	if err != nil {
		return cloudflareAPI{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return cloudflareAPI{}, errors.New("Cloudflare API token file must be a private regular file (chmod 600)")
	}
	token, err := os.ReadFile(settings.TokenFile)
	if err != nil {
		return cloudflareAPI{}, err
	}
	if len(strings.TrimSpace(string(token))) == 0 {
		return cloudflareAPI{}, errors.New("Cloudflare API token file is empty")
	}
	return cloudflareAPI{token: strings.TrimSpace(string(token)), base: "https://api.cloudflare.com/client/v4", client: &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("Cloudflare redirect refused") }}}, nil
}

func tunnelCommand(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: devenv tunnel configure|status|retire [flags]")
	}
	action := args[0]
	cfg, err := baseConfig()
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet("tunnel "+action, flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.StringVar(&cfg.Root, "root", cfg.Root, "workspace state directory")
	settings, loadErr := loadTunnelSettings()
	if loadErr != nil && !errors.Is(loadErr, os.ErrNotExist) {
		return loadErr
	}
	if action == "configure" {
		if settings.Origin == "" {
			settings.Origin = "http://workspace:8080"
		}
		fs.StringVar(&settings.AccountID, "account-id", settings.AccountID, "Cloudflare account ID")
		fs.StringVar(&settings.ZoneID, "zone-id", settings.ZoneID, "Cloudflare zone ID")
		fs.StringVar(&settings.Domain, "domain", settings.Domain, "owned zone domain")
		fs.StringVar(&settings.TokenFile, "api-token-file", settings.TokenFile, "host-only Cloudflare API token file")
		fs.StringVar(&settings.Origin, "origin", settings.Origin, "single HTTP Docker-network origin")
		fs.StringVar(&settings.Cloudflared, "cloudflared", settings.Cloudflared, "native cloudflared executable (default PATH)")
	} else if action != "status" && action != "retire" {
		return fmt.Errorf("unknown tunnel action %q", action)
	}
	if err = fs.Parse(args[1:]); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	cfg, err = normalizeConfig(cfg)
	if err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	wt, worktreeErr := resolveWorktree(cwd)
	var current *worktree
	if worktreeErr == nil {
		current = &wt
	}
	if action == "configure" {
		settings.TokenFile, err = canonicalFuturePath(settings.TokenFile)
		if err != nil {
			return err
		}
		if err = validateTunnelSettings(settings); err != nil {
			return err
		}
	}
	if err = validateTunnelPaths(cfg, current, &settings); err != nil {
		return err
	}
	unlock, err := lockTunnels()
	if err != nil {
		return err
	}
	defer unlock()
	if action == "configure" {
		if _, err = tunnelAPI(settings); err != nil {
			return err
		}
		if err = validateManagedTunnelPaths(ctx, settings); err != nil {
			return err
		}
		home, _ := tunnelHome()
		if err = writePrivateJSON(filepath.Join(home, "config.json"), settings); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "Host tunnel settings saved. Run devenv up --tunnel from a worktree to opt in.")
		return nil
	}
	if worktreeErr != nil {
		return worktreeErr
	}
	state, path, err := loadTunnel(wt)
	if err != nil {
		return err
	}
	if state == nil {
		fmt.Fprintln(stdout, "No public tunnel allocated for this worktree.")
		return nil
	}
	if action == "status" {
		fmt.Fprintf(stdout, "Instance: %s\nEnabled: %t\nRetired: %t\nApp: https://%s\nFiles: https://%s\nIngress network: %s\n", state.ID, state.Enabled, state.Retired, state.appHost(), state.filesHost(), state.network())
		return nil
	}
	if state.Root != cfg.Root {
		return errors.New("this worktree's tunnel belongs to a different devenv root; reuse its original --root")
	}
	if err = stopTunnelRuntime(ctx, *state, path); err != nil {
		return err
	}
	state.Process = nil
	state.Enabled = false
	if err = writePrivateJSON(path, state); err != nil {
		return err
	}
	if state.Retired {
		return nil
	}
	api, err := tunnelAPI(settings)
	if err != nil {
		return err
	}
	if err = api.retire(ctx, state); err != nil {
		return err
	}
	if err = finishTunnelRetirement(path, state); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "Tunnel retired. A later explicit devenv up --tunnel creates a new allocation; plain up remains private.")
	return nil
}

func finishTunnelRetirement(path string, state *tunnelState) error {
	if err := removeTunnelToken(path); err != nil {
		return err
	}
	state.Retired = true
	return writePrivateJSON(path, state)
}

func removeTunnelToken(path string) error {
	err := os.Remove(filepath.Join(filepath.Dir(path), "runtime-token"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
