package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestTunnelContainerLifecycle(t *testing.T) {
	dir := t.TempDir()
	state := tunnelState{ID: testTunnelID, Root: "/env", GitDir: "/repo/.git", Origin: "http://workspace:8080"}
	t.Setenv("DEVENV_DOCKER_FIXTURE", dir)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
set -eu
cd "$DEVENV_DOCKER_FIXTURE"
case "$1" in
network) cat network ;;
container) if test -f current; then cat current; else printf '[]\n'; fi ;;
run) printf 'run\n' >> events; if test -f fail; then cp failed current; else cp ready current; fi ;;
rm) printf 'rm\n' >> events; rm -f current ;;
*) echo 'unexpected Docker command' >&2; exit 1 ;;
esac
`
	write := func(name string, body []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), body, 0700); err != nil {
			t.Fatal(err)
		}
	}
	write("docker", []byte(script))
	write("network", []byte("bridge false "+state.ID+" "+state.GitDir))
	info := containerInspect{}
	info.Config.Labels = map[string]string{labelManaged: "true", labelRole: "tunnel", labelRoot: state.Root, labelWorktreeGitDir: state.GitDir, tunnelInstanceLabel: state.ID}
	info.Config.Image = tunnelImage
	info.State.Running = true
	save := func(name string, value containerInspect) {
		t.Helper()
		data, err := json.Marshal([]containerInspect{value})
		if err != nil {
			t.Fatal(err)
		}
		write(name, data)
	}
	save("ready", info)
	failed := info
	failed.State.Running = false
	save("failed", failed)
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		fmt.Fprint(w, `{"success":true,"result":{}}`)
	}))
	defer server.Close()
	api := cloudflareAPI{base: server.URL, client: server.Client()}
	ctx := context.Background()
	start := func() {
		t.Helper()
		if err := startTunnelRuntime(ctx, &state, filepath.Join(dir, "state.json"), api); err != nil {
			t.Fatal(err)
		}
	}
	events := func(want string) {
		t.Helper()
		got, err := os.ReadFile(filepath.Join(dir, "events"))
		if err != nil || string(got) != want {
			t.Fatalf("events=%q want=%q err=%v", got, want, err)
		}
	}
	start()
	events("run\n")
	start()
	events("run\n")
	save("current", failed)
	start()
	events("run\nrm\nrun\n")
	outdated := info
	outdated.Config.Image = "cloudflare/cloudflared:older"
	save("current", outdated)
	start()
	events("run\nrm\nrun\nrm\nrun\n")
	if requests != 4 {
		t.Fatalf("route refresh count=%d", requests)
	}
	// Reject a foreign allocation before changing its remote routing or container.
	foreign := info
	foreign.Config.Labels = map[string]string{labelManaged: "true", tunnelInstanceLabel: "other"}
	save("current", foreign)
	if err := startTunnelRuntime(ctx, &state, filepath.Join(dir, "state.json"), api); err == nil {
		t.Fatal("accepted foreign container")
	}
	if err := stopTunnelRuntime(ctx, state); err == nil {
		t.Fatal("removed foreign container")
	}
	if requests != 4 {
		t.Fatal("foreign container changed remote routing")
	}
	events("run\nrm\nrun\nrm\nrun\n")
	save("current", info)
	if err := stopTunnelRuntime(ctx, state); err != nil {
		t.Fatal(err)
	}
	if err := stopTunnelRuntime(ctx, state); err != nil {
		t.Fatal(err)
	}
	events("run\nrm\nrun\nrm\nrun\nrm\n")
	write("fail", nil)
	if err := startTunnelRuntime(ctx, &state, filepath.Join(dir, "state.json"), api); err == nil || !strings.Contains(err.Error(), "did not stay running") {
		t.Fatalf("early exit: %v", err)
	}
	state.LegacyProcess = json.RawMessage(`{"pid":123}`)
	if err := startTunnelRuntime(ctx, &state, filepath.Join(dir, "state.json"), api); err == nil {
		t.Fatal("accepted active native runtime")
	}
	if requests != 5 {
		t.Fatal("native runtime changed remote routing")
	}
}

func TestTunnelTokenMount(t *testing.T) {
	// Docker --mount uses CSV: a comma or quote in a host path must stay literal.
	dir := filepath.Join(t.TempDir(), `private, "token" directory`)
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "state.json")
	token := filepath.Join(dir, "runtime-token")
	const secret = "fixture-runtime-credential"
	if err := writePrivate(token, []byte(secret)); err != nil {
		t.Fatal(err)
	}
	args := tunnelArgs(tunnelState{ID: testTunnelID}, path)
	idx := slices.Index(args, "--mount")
	fields, err := csv.NewReader(strings.NewReader(args[idx+1])).Read()
	if err != nil || !slices.Equal(fields, []string{"type=bind", "source=" + token, "target=" + tunnelTokenPath, "readonly"}) {
		t.Fatalf("mount=%q error=%v", fields, err)
	}
	for _, arg := range args {
		if strings.Contains(arg, secret) {
			t.Fatal("credential in container arguments")
		}
	}
	info, err := os.Stat(token)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("token permissions: %v %v", info, err)
	}
	idx = slices.Index(args, "--user")
	if args[idx+1] != fmt.Sprintf("%d:%d", os.Getuid(), os.Getgid()) {
		t.Fatal("sidecar cannot read host-owned token")
	}
}
