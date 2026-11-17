package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Test the dedicated network, Docker DNS, Host routing and owned-container
// lifecycle with the real cloudflared image. Public HTTPS needs a live account.
func TestTunnelDockerNetwork(t *testing.T) {
	if os.Getenv("DEVENV_TEST_DOCKER") != "1" {
		t.Skip("set DEVENV_TEST_DOCKER=1 to exercise Docker networking")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	run := func(args ...string) string {
		t.Helper()
		out, err := dockerOutput(ctx, args...)
		if err != nil {
			t.Fatalf("docker %v: %v", args, err)
		}
		return strings.TrimSpace(out)
	}
	arch := run("info", "--format", "{{.Architecture}}")
	switch arch {
	case "aarch64":
		arch = "arm64"
	case "x86_64":
		arch = "amd64"
	}
	dir := t.TempDir()
	source, binary := filepath.Join(dir, "probe.go"), filepath.Join(dir, "probe")
	code := `package main
import("flag";"fmt";"io";"net/http";"os";"time")
func main(){endpoint:=flag.String("url","","");host:=flag.String("host","","");flag.Parse();if *endpoint!="" {client:=http.Client{Timeout:time.Second};for i:=0;i<30;i++ {req,_:=http.NewRequest("GET",*endpoint,nil);req.Host=*host;res,err:=client.Do(req);if err==nil {io.Copy(os.Stdout,res.Body);res.Body.Close();return};time.Sleep(100*time.Millisecond)};os.Exit(1)};http.HandleFunc("/",func(w http.ResponseWriter,r *http.Request){switch r.Host {case "app.example.dev":fmt.Fprint(w,"app");case "files.example.dev":fmt.Fprint(w,"files");default:http.NotFound(w,r)}});if err:=http.ListenAndServe(":8080",nil);err!=nil {panic(err)}}`
	if err := os.WriteFile(source, []byte(code), 0600); err != nil {
		t.Fatal(err)
	}
	build := exec.CommandContext(ctx, "go", "build", "-trimpath", "-o", binary, source)
	build.Env = append(os.Environ(), "GOOS=linux", "GOARCH="+arch, "CGO_ENABLED=0")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build fixture: %s %v", out, err)
	}
	suffix, err := randomSuffix(12)
	if err != nil {
		t.Fatal(err)
	}
	fixtureImage := "devenv-tunnel-test:" + suffix
	if err = writePrivate(filepath.Join(dir, "runtime-token"), []byte("intentionally-invalid-fixture-token")); err != nil {
		t.Fatal(err)
	}
	user := fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid())
	dockerfile := "FROM " + tunnelImage + "\nCOPY probe /probe\nCOPY --chown=" + user + " runtime-token " + tunnelTokenPath + "\n"
	if err = os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte(dockerfile), 0600); err != nil {
		t.Fatal(err)
	}
	run("build", "-q", "-t", fixtureImage, dir)
	defer dockerOutput(context.Background(), "image", "rm", fixtureImage)
	// Real cloudflared must read the owner-only file under the sidecar's user
	// and hardening settings. Rejecting its synthetic contents happens before
	// any connection; network=none guarantees this stays an offline check.
	reader := "devenv-token-test-" + suffix
	defer dockerOutput(context.Background(), "rm", "-f", reader)
	check := exec.CommandContext(ctx, "docker", "run", "--rm", "--name", reader, "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--user", user, fixtureImage, "tunnel", "--no-autoupdate", "run", "--token-file", tunnelTokenPath)
	if out, err := check.CombinedOutput(); err == nil || !strings.Contains(string(out), "Provided Tunnel token is not valid") {
		t.Fatalf("cloudflared token-file read: %s %v", out, err)
	}
	state := tunnelState{ID: "test-" + suffix, Root: dir, GitDir: filepath.Join(dir, "repo", ".git"), Origin: "http://workspace:8080"}
	if err = ensureTunnelNetwork(ctx, state); err != nil {
		t.Fatal(err)
	}
	defer dockerOutput(context.Background(), "network", "rm", state.network())
	target := "devenv-origin-test-" + suffix
	defer dockerOutput(context.Background(), "rm", "-f", target)
	defer dockerOutput(context.Background(), "rm", "-f", state.container())
	// Inject a static HTTP probe in place of cloudflared. The production sidecar
	// flags are retained except the host token mount (not available to remote CI).
	args := tunnelArgs(state, filepath.Join(dir, "state.json"))
	fixture := []string{"create"}
	for i := 2; i < len(args); i++ {
		if args[i] == "--mount" {
			i++
			continue
		}
		if args[i] == tunnelImage {
			fixture = append(fixture, "--entrypoint", "/probe", fixtureImage)
			break
		}
		fixture = append(fixture, args[i])
	}
	run(fixture...)
	run("start", state.container())
	cfg := config{Root: state.Root}
	wt := worktree{GitDir: state.GitDir}
	// Startup creates the tunnel first. Its matching root/Git-directory labels
	// must not make the workspace lookup adopt it as an existing workspace.
	if id, _, exists, err := findWorktreeContainer(ctx, cfg, wt); err != nil || exists {
		t.Fatalf("tunnel-only workspace lookup: id=%q exists=%t err=%v", id, exists, err)
	}
	workspaceArgs := []string{"create", "--name", target, "--network", state.network(), "--network-alias", "workspace",
		"--label", labelManaged + "=true", "--label", labelRole + "=workspace",
		"--label", labelRoot + "=" + state.Root, "--label", labelWorktreeGitDir + "=" + state.GitDir,
		"--entrypoint", "/probe"}
	for _, value := range state.environment() {
		workspaceArgs = append(workspaceArgs, "-e", value)
	}
	workspaceID := run(append(workspaceArgs, fixtureImage)...)
	run("start", target)
	if id, info, exists, err := findWorktreeContainer(ctx, cfg, wt); err != nil || !exists || id == "" || !strings.HasPrefix(workspaceID, id) || !workspaceTunnelMatches(info, &state) {
		t.Fatalf("workspace with tunnel lookup: id=%q exists=%t err=%v", id, exists, err)
	}
	for restart := 0; restart < 2; restart++ {
		for _, route := range []string{"app", "files"} {
			got := run("exec", state.container(), "/probe", "-url", state.Origin, "-host", route+".example.dev")
			if got != route {
				t.Fatalf("Host route %s returned %q", route, got)
			}
		}
		if restart == 0 {
			run("restart", state.container())
		}
	}
	if err = stopTunnelRuntime(ctx, state); err != nil {
		t.Fatal(err)
	}
	if err = stopTunnelRuntime(ctx, state); err != nil {
		t.Fatalf("retry stop: %v", err)
	}
	// A name collision must leave the foreign container intact.
	run("create", "--name", state.container(), tunnelImage, "--version")
	if err = stopTunnelRuntime(ctx, state); err == nil {
		t.Fatal("removed foreign container")
	}
	if _, exists, err := inspectContainer(ctx, state.container()); err != nil || !exists {
		t.Fatalf("foreign container lost: %v", err)
	}
}
