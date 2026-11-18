package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestEngineStorageAndCacheScope(t *testing.T) {
	a, b := config{Root: "/env/a"}, config{Root: "/env/b"}
	if engineVolume(a, "one") == engineVolume(a, "two") || engineVolume(a, "one") == engineVolume(b, "one") {
		t.Fatal("independent engines share storage")
	}
	if cacheNetwork(a) == cacheNetwork(b) {
		t.Fatal("different roots share registry network")
	}
	main := worktree{CommonDir: "/repo/.git", GitDir: "/repo/.git"}
	branch := worktree{CommonDir: "/repo/.git", GitDir: "/repo/.git/worktrees/feature"}
	if buildCacheRepository(main) != buildCacheRepository(branch) {
		t.Fatal("worktrees cannot reuse each other's builds")
	}
	if buildCacheRepository(main) == buildCacheRepository(worktree{CommonDir: "/other/.git"}) {
		t.Fatal("unrelated repositories share cache manifests")
	}
	for _, mirror := range []bool{true, false} {
		args := registryArgs(a, mirror)
		if containsArgPair(args, "-e", "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io") != mirror {
			t.Fatal("writable build registry configured as pull-through proxy")
		}
		for _, arg := range args {
			if arg == "-p" || arg == "--publish" || strings.Contains(arg, "docker.sock") || strings.Contains(arg, "type=bind") {
				t.Fatalf("registry exposes host resources: %v", args)
			}
		}
	}
}

func TestDockerBuildCacheWrapper(t *testing.T) {
	for _, command := range []string{"bash", "sha256sum", "jq"} {
		if _, err := exec.LookPath(command); err != nil {
			t.Skipf("Linux runtime wrapper needs %s", command)
		}
	}
	// Execute the real wrapper, substituting only the Docker binary. No daemon,
	// registry or shell-string evaluation is needed to inspect argument fidelity.
	dir := t.TempDir()
	script, err := os.ReadFile("../../runtime/docker")
	if err != nil {
		t.Fatal(err)
	}
	stub := filepath.Join(dir, "real-docker")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nprintf '%s\\n' \"$@\"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	wrapper := filepath.Join(dir, "docker")
	if err := os.WriteFile(wrapper, []byte(strings.Replace(string(script), "real=/usr/bin/docker", "real="+stub, 1)), 0755); err != nil {
		t.Fatal(err)
	}
	// A fake tags response proves we import other worktrees, and reject arbitrary
	// tag strings before turning them into cache arguments.
	if err := os.WriteFile(filepath.Join(dir, "curl"), []byte("#!/bin/sh\nprintf '%s\\n' '{\"tags\":[\"cache-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"unrelated\"]}'\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DOCKER_HOST", "unix:///var/run/docker.sock")
	t.Setenv("DOCKER_CONTEXT", "")
	t.Setenv("BUILDX_BUILDER", "default")
	t.Setenv("DOCKER_BUILDKIT", "1")
	t.Setenv("DEVENV_SHARED_BUILD_CACHE", "1")
	t.Setenv("DEVENV_BUILD_CACHE_REGISTRY", "devenv-cache:5000")
	t.Setenv("DEVENV_BUILD_CACHE_REPO", "buildcache/test")
	for _, args := range [][]string{{"run", "-p", "8080:80", "nginx"}, {"compose", "up"}, {"build", "--help"}, {"build", "--cache-to", "type=local,dest=mine", "."}, {"buildx", "build", "--builder", "other", "."}} {
		out, err := commandOutput(context.Background(), wrapper, args...)
		if err != nil {
			t.Fatal(err)
		}
		if out != strings.Join(args, "\n")+"\n" {
			t.Fatalf("changed explicit request %v: %s", args, out)
		}
	}
	for _, prefix := range [][]string{{"build"}, {"buildx", "build"}} {
		args := append(prefix, "-t", "my-app", "a directory with spaces")
		out, err := commandOutput(context.Background(), wrapper, args...)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(out, "buildx\nbuild\n--cache-to\n") || !strings.Contains(out, "mode=max") || !strings.Contains(out, "--cache-from\ntype=registry,ref=devenv-cache:5000/buildcache/test:cache-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") || !strings.HasSuffix(out, "-t\nmy-app\na directory with spaces\n") {
			t.Fatalf("wrong cache arguments: %s", out)
		}
	}
}

func commandOutput(ctx context.Context, path string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, path, args...).CombinedOutput()
	return string(out), err
}
