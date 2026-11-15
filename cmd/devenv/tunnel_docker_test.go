package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Opt in with DEVENV_TEST_DOCKER=1. This tests the actual credential-free Docker
// leg, including Host routing and restart, without needing a Cloudflare account.
func TestTunnelDockerRelay(t *testing.T) {
	if os.Getenv("DEVENV_TEST_DOCKER") != "1" {
		t.Skip("set DEVENV_TEST_DOCKER=1 to exercise the Docker relay")
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
	source := filepath.Join(dir, "probe.go")
	binary := filepath.Join(dir, "probe")
	code := `package main
import("flag";"fmt";"io";"net/http";"os";"time")
func main(){endpoint:=flag.String("url","","");host:=flag.String("host","","");flag.Parse();if *endpoint!="" {client:=http.Client{Timeout:time.Second};for i:=0;i<30;i++ {req,_:=http.NewRequest("GET",*endpoint,nil);req.Host=*host;res,err:=client.Do(req);if err==nil {io.Copy(os.Stdout,res.Body);res.Body.Close();return};time.Sleep(100*time.Millisecond)};os.Exit(1)};http.HandleFunc("/",func(w http.ResponseWriter,r *http.Request){switch r.Host {case "app.example.dev":fmt.Fprint(w,"app");case "files.example.dev":fmt.Fprint(w,"files");default:http.NotFound(w,r)}});if err:=http.ListenAndServe(":80",nil);err!=nil {panic(err)}}`
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
	state := tunnelState{ID: "test-" + suffix, Root: "/test", GitDir: "/test/.git", Origin: "http://houston:80"}
	target := "devenv-relay-test-" + suffix
	run("network", "create", state.network())
	defer dockerOutput(context.Background(), "network", "rm", state.network())
	run("create", "--name", target, "--network", state.network(), "--network-alias", "houston", "--entrypoint", "/probe", tunnelRelayImage)
	defer dockerOutput(context.Background(), "rm", "-f", target)
	run("cp", binary, target+":/probe")
	run("start", target)
	defer dockerOutput(context.Background(), "rm", "-f", state.relay())
	for restart := 0; restart < 2; restart++ {
		run(relayArgs(state)...)
		info, exists, err := inspectContainer(ctx, state.relay())
		if err != nil || !exists {
			t.Fatalf("inspect relay: %v", err)
		}
		if _, err = relayPort(info); err != nil {
			t.Fatal(err)
		}
		for _, route := range []string{"app", "files"} {
			got := run("exec", target, "/probe", "-url", "http://"+state.relay()+":8080", "-host", route+".example.dev")
			if got != route {
				t.Fatalf("Host route %s returned %q", route, got)
			}
		}
		run("rm", "-f", state.relay())
	}
}
