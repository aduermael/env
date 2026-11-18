package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testTunnelID = "01234567-89ab-4cde-8f01-23456789abcd"

func TestTunnelPrivatePathsAndPersistentIdentity(t *testing.T) {
	base := t.TempDir()
	private := filepath.Join(base, "private")
	root := filepath.Join(base, "env")
	repo := filepath.Join(base, "repo")
	for _, p := range []string{private, root, repo} {
		if err := os.MkdirAll(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DEVENV_TUNNEL_HOME", private)
	cfg := config{Root: root}
	wt := worktree{GitDir: filepath.Join(repo, ".git", "worktrees", "same"), RepoRoot: repo, CheckoutPath: filepath.Join(repo, "same")}
	settings := tunnelSettings{TokenFile: filepath.Join(private, "api-token")}
	if err := validateTunnelPaths(cfg, &wt, &settings); err != nil {
		t.Fatal(err)
	}
	path, err := tunnelStatePath(wt)
	if err != nil {
		t.Fatal(err)
	}
	state := tunnelState{GitDir: wt.GitDir, ID: testTunnelID, Enabled: true}
	if err = writePrivateJSON(path, state); err != nil {
		t.Fatal(err)
	}
	wt.CheckoutPath = filepath.Join(repo, "renamed")
	got, movedPath, err := loadTunnel(wt)
	if err != nil || movedPath != path || got.ID != testTunnelID {
		t.Fatalf("move lost binding: %+v %s %v", got, movedPath, err)
	}
	other := wt
	other.GitDir = filepath.Join(base, "other", ".git", "worktrees", "same")
	otherPath, _ := tunnelStatePath(other)
	if otherPath == path {
		t.Fatal("same-name worktrees collided")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("state is not private")
	}
	settings.TokenFile = filepath.Join(repo, "token")
	if err = validateTunnelPaths(cfg, &wt, &settings); err == nil {
		t.Fatal("accepted token in mounted repository")
	}
	link := filepath.Join(base, "link")
	if err = os.Symlink(repo, link); err != nil {
		t.Fatal(err)
	}
	settings.TokenFile = filepath.Join(link, "future", "token")
	if err = validateTunnelPaths(cfg, &wt, &settings); err == nil {
		t.Fatal("accepted symlink into mounted repository")
	}
	settings.TokenFile = filepath.Join(private, "api-token")
	t.Setenv("DEVENV_TUNNEL_HOME", filepath.Join(root, "private"))
	if err = validateTunnelPaths(cfg, &wt, &settings); err == nil {
		t.Fatal("accepted state inside mounted env root")
	}
}

func TestTunnelAllocationRetriesAndRetirementOwnership(t *testing.T) {
	state := tunnelState{GitDir: "/repo/.git", Name: "devenv-request", AccountID: "account", ZoneID: "zone", Domain: "example.dev", DNSRecords: map[string]string{}}
	path := filepath.Join(t.TempDir(), "state.json")
	var created bool
	creates := 0
	deletes := 0
	failCreate := true
	foreign := false
	records := map[string]cloudflareDNS{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reply := func(value any) { json.NewEncoder(w).Encode(map[string]any{"success": true, "result": value}) }
		switch {
		case r.URL.Path == "/zones/zone":
			reply(map[string]string{"name": "example.dev"})
		case r.URL.Path == "/accounts/account/cfd_tunnel" && r.Method == "GET":
			result := []cloudflareTunnel{}
			if created {
				result = append(result, cloudflareTunnel{ID: testTunnelID, Name: state.Name})
			}
			reply(result)
		case r.URL.Path == "/accounts/account/cfd_tunnel" && r.Method == "POST":
			creates++
			created = true
			if failCreate {
				failCreate = false
				w.WriteHeader(502)
				fmt.Fprint(w, "lost response")
				return
			}
			reply(cloudflareTunnel{ID: testTunnelID, Name: state.Name})
		case strings.HasSuffix(r.URL.Path, "/token"):
			reply("runtime-secret")
		case r.URL.Path == "/accounts/account/cfd_tunnel/"+testTunnelID:
			if r.Method == "DELETE" {
				deletes++
			}
			reply(cloudflareTunnel{ID: testTunnelID, Name: state.Name})
		case r.URL.Path == "/zones/zone/dns_records" && r.Method == "POST":
			var record cloudflareDNS
			if err := json.NewDecoder(r.Body).Decode(&record); err != nil {
				t.Error(err)
			}
			record.ID = fmt.Sprint(len(records) + 1)
			records[record.ID] = record
			reply(record)
		case r.URL.Path == "/zones/zone/dns_records":
			result := []cloudflareDNS{}
			for _, record := range records {
				if record.Name == r.URL.Query().Get("name") {
					if foreign {
						record.Content = "foreign.example"
					}
					result = append(result, record)
				}
			}
			reply(result)
		case strings.HasPrefix(r.URL.Path, "/zones/zone/dns_records/"):
			id := strings.TrimPrefix(r.URL.Path, "/zones/zone/dns_records/")
			record := records[id]
			if r.Method == "DELETE" {
				deletes++
				delete(records, id)
			}
			reply(record)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL)
			w.WriteHeader(500)
		}
	}))
	defer server.Close()
	api := cloudflareAPI{base: server.URL, token: "private-api-token", client: server.Client()}
	if err := writePrivateJSON(path, state); err != nil {
		t.Fatal(err)
	}
	if err := api.allocate(context.Background(), &state, path); err == nil {
		t.Fatal("ambiguous delivery should fail first attempt")
	}
	if err := api.allocate(context.Background(), &state, path); err != nil {
		t.Fatal(err)
	}
	if creates != 1 || state.ID != testTunnelID || len(records) != 2 {
		t.Fatalf("retry allocated duplicate: creates=%d state=%+v records=%v", creates, state, records)
	}
	if err := api.allocate(context.Background(), &state, path); err != nil {
		t.Fatal(err)
	}
	saved := tunnelState{}
	if err := readJSON(path, &saved); err != nil || saved.ID != testTunnelID {
		t.Fatalf("identity not persisted: %v", err)
	}
	foreign = true
	if err := api.retire(context.Background(), &state); err == nil {
		t.Fatal("retired reassigned DNS")
	}
	if deletes != 0 {
		t.Fatal("partial destructive retirement before ownership validation")
	}
	foreign = false
	if err := api.retire(context.Background(), &state); err != nil {
		t.Fatal(err)
	}
	if deletes != 3 {
		t.Fatalf("retirement deletes=%d", deletes)
	}
}

func TestTunnelRoutingAndMetadata(t *testing.T) {
	state := tunnelState{ID: testTunnelID, Domain: "example.dev", Origin: "http://houston:80", Root: "/env", GitDir: "/repo/.git"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Config struct{ Ingress []map[string]string }
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		rules := body.Config.Ingress
		if len(rules) != 3 || rules[0]["hostname"] != state.appHost() || rules[1]["hostname"] != state.filesHost() || rules[0]["service"] != state.Origin || rules[1]["service"] != rules[0]["service"] || rules[2]["service"] != "http_status:404" {
			t.Errorf("invalid routes: %+v", rules)
		}
		fmt.Fprint(w, `{"success":true,"result":{}}`)
	}))
	defer server.Close()
	if err := (cloudflareAPI{base: server.URL, client: server.Client()}).route(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	cfg := config{Root: "/env", PublicTunnel: &state}
	wt := worktree{RepoRoot: "/repo", GitDir: "/repo/.git"}
	args := strings.Join(workspaceRunArgs(cfg, wt, worktreeRecord{ID: "same", Port: 1234}, 1000, 1000), " ")
	for _, value := range state.environment() {
		if !strings.Contains(args, value) {
			t.Errorf("missing metadata %s", value)
		}
	}
	for _, input := range []struct {
		args         []string
		set, enabled bool
	}{{[]string{}, false, false}, {[]string{"--tunnel"}, true, true}, {[]string{"--tunnel=false"}, true, false}} {
		cfg, err := parseUpFlags(input.args)
		if err != nil || cfg.TunnelSet != input.set || cfg.Tunnel != input.enabled {
			t.Fatalf("flags %v: %+v %v", input.args, cfg, err)
		}
	}
}

func TestTunnelSecretsRejectOtherRootMounts(t *testing.T) {
	base := t.TempDir()
	repoA := filepath.Join(base, "repo-a")
	private := filepath.Join(base, "private")
	if err := os.MkdirAll(repoA, 0700); err != nil {
		t.Fatal(err)
	}
	if err := validateProtectedRoots([]string{private, filepath.Join(repoA, "api-token")}, []string{repoA}); err == nil {
		t.Fatal("accepted credentials in another workspace's bind mount")
	}
	link := filepath.Join(base, "repo-link")
	if err := os.Symlink(repoA, link); err != nil {
		t.Fatal(err)
	}
	canonical, err := canonicalFuturePath(filepath.Join(link, "api-token"))
	if err != nil {
		t.Fatal(err)
	}
	if err = validateProtectedRoots([]string{private, canonical}, []string{repoA}); err == nil {
		t.Fatal("accepted credential symlink into another workspace")
	}
	if err = validateProtectedRoots([]string{private, filepath.Join(private, "api-token")}, []string{repoA}); err != nil {
		t.Fatal(err)
	}
}

func TestMovedWorktreeRegistryKeepsMachine(t *testing.T) {
	wt := worktree{GitDir: "/repo/.git/worktrees/same", CheckoutPath: "/repo/old", CommonDir: "/repo/.git"}
	reg := registry{Worktrees: map[string]*worktreeRecord{wt.GitDir: {ID: "stable", Port: 1234, WorktreePath: wt.CheckoutPath, GitCommonDir: wt.CommonDir}}}
	wt.CheckoutPath = "/repo/new"
	record, changed, err := reg.ensureRecord(wt, nil, nil)
	if err != nil || !changed || record.ID != "stable" || record.Port != 1234 || record.WorktreePath != wt.CheckoutPath {
		t.Fatalf("move changed identity or lost new path: %+v %t %v", record, changed, err)
	}
}

func TestTunnelWrongRootCannotStopOrDisable(t *testing.T) {
	t.Setenv("DEVENV_TUNNEL_HOME", t.TempDir())
	wt := worktree{GitDir: "/repo/.git"}
	path, _ := tunnelStatePath(wt)
	original := tunnelState{GitDir: wt.GitDir, Root: "/root-a", ID: testTunnelID, Enabled: true}
	if err := writePrivateJSON(path, original); err != nil {
		t.Fatal(err)
	}
	cfg := config{Root: "/root-b", TunnelSet: true, Tunnel: false}
	if err := stopWorktreeTunnel(context.Background(), cfg, wt); err == nil || !strings.Contains(err.Error(), "different devenv root") {
		t.Fatalf("wrong root stop: %v", err)
	}
	if _, err := prepareTunnel(context.Background(), cfg, wt); err == nil || !strings.Contains(err.Error(), "different devenv root") {
		t.Fatalf("wrong root disable: %v", err)
	}
	got, _, err := loadTunnel(wt)
	if err != nil || !got.Enabled || got.Root != original.Root {
		t.Fatalf("binding changed: %+v %v", got, err)
	}
}

func TestTunnelRetirementTokenCleanupMustCompleteBeforeReuse(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	token := filepath.Join(dir, "runtime-token")
	state := tunnelState{ID: testTunnelID, Enabled: false}
	if err := writePrivateJSON(path, state); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(token, 0700); err != nil {
		t.Fatal(err)
	}
	blocked := filepath.Join(token, "blocked")
	if err := os.WriteFile(blocked, []byte("old credential"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := finishTunnelRetirement(path, &state); err == nil {
		t.Fatal("accepted incomplete credential cleanup")
	}
	var saved tunnelState
	if err := readJSON(path, &saved); err != nil || saved.Retired {
		t.Fatalf("failed cleanup enabled new allocation: %+v %v", saved, err)
	}
	if err := os.RemoveAll(token); err != nil {
		t.Fatal(err)
	}
	if err := writePrivate(token, []byte("old runtime token")); err != nil {
		t.Fatal(err)
	}
	if err := finishTunnelRetirement(path, &state); err != nil {
		t.Fatal(err)
	}
	if err := readJSON(path, &saved); err != nil || !saved.Retired {
		t.Fatalf("retirement not durable: %+v %v", saved, err)
	}
	if err := writePrivate(token, []byte("new allocation token")); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(token)
	if err != nil || string(got) != "new allocation token" {
		t.Fatalf("new allocation reused old token: %s %v", got, err)
	}
}

type tunnelFixtureTransport func(*http.Request) (*http.Response, error)

func (f tunnelFixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestTunnelOriginDefaultDoesNotRetargetExistingAllocation(t *testing.T) {
	base := t.TempDir()
	home := filepath.Join(base, "private")
	bin := filepath.Join(base, "bin")
	t.Setenv("DEVENV_TUNNEL_HOME", home)
	t.Setenv("DOCKER_HOST", "unix:///fixture-docker.sock")
	t.Setenv("DOCKER_CONTEXT", "")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	docker := `#!/bin/sh
case "$1" in
ps) exit 0 ;;
container) printf '[]\n' ;;
*) echo "unexpected fixture Docker command" >&2; exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "docker"), []byte(docker), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	settings := tunnelSettings{AccountID: strings.Repeat("a", 32), ZoneID: strings.Repeat("b", 32), Domain: "example.dev", TokenFile: filepath.Join(home, "api-token"), Origin: "http://workspace:8080"}
	if err := writePrivate(settings.TokenFile, []byte("fixture-api-token")); err != nil {
		t.Fatal(err)
	}
	if err := writePrivateJSON(filepath.Join(home, "config.json"), settings); err != nil {
		t.Fatal(err)
	}
	originalTransport := http.DefaultTransport
	http.DefaultTransport = tunnelFixtureTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != "GET" || r.URL.Path != "/client/v4/zones/"+settings.ZoneID {
			t.Errorf("unexpected provisioning request %s %s", r.Method, r.URL)
		}
		return nil, fmt.Errorf("fixture stops before remote provisioning")
	})
	t.Cleanup(func() { http.DefaultTransport = originalTransport })
	cfg := config{Root: filepath.Join(base, "env"), Tunnel: true, TunnelSet: true}
	first := worktree{GitDir: filepath.Join(base, "first", ".git"), RepoRoot: filepath.Join(base, "first"), CheckoutPath: filepath.Join(base, "first")}
	prepare := func(wt worktree) *tunnelState {
		t.Helper()
		_, err := prepareTunnel(context.Background(), cfg, wt)
		if err == nil || !strings.Contains(err.Error(), "fixture stops before remote provisioning") {
			t.Fatalf("unexpected prepare result: %v", err)
		}
		state, _, err := loadTunnel(wt)
		if err != nil || state == nil {
			t.Fatalf("missing prepared binding: %+v %v", state, err)
		}
		return state
	}
	original := prepare(first)
	if original.Origin != settings.Origin {
		t.Fatalf("initial origin=%s", original.Origin)
	}
	original.ID = testTunnelID
	path, _ := tunnelStatePath(first)
	if err := writePrivateJSON(path, original); err != nil {
		t.Fatal(err)
	}
	settings.Origin = "http://houston:80"
	if err := writePrivateJSON(filepath.Join(home, "config.json"), settings); err != nil {
		t.Fatal(err)
	}
	existing := prepare(first)
	if existing.ID != original.ID || existing.Name != original.Name || existing.Origin != original.Origin {
		t.Fatalf("existing allocation retargeted: %+v", existing)
	}
	second := worktree{GitDir: filepath.Join(base, "second", ".git"), RepoRoot: filepath.Join(base, "second"), CheckoutPath: filepath.Join(base, "second")}
	fresh := prepare(second)
	if fresh.Origin != settings.Origin || fresh.Name == original.Name {
		t.Fatalf("new allocation did not use new default: %+v", fresh)
	}
}
