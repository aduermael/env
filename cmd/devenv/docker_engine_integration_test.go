package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Uses only uniquely named test resources and no host bind mounts. It can run
// through the old filtering proxy on OrbStack while the current workspace lives.
func TestNestedDocker(t *testing.T) {
	if os.Getenv("DEVENV_TEST_DIND") != "1" {
		t.Skip("set DEVENV_TEST_DIND=1 to exercise nested Docker and shared caches")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	run := func(args ...string) string {
		t.Helper()
		out, err := dockerOutput(ctx, args...)
		if err != nil {
			t.Fatalf("docker %v: %v", args, err)
		}
		return strings.TrimSpace(out)
	}
	dir := t.TempDir()
	cfg := config{Root: dir}
	if err := os.MkdirAll(filepath.Join(cfg.Root, "run"), 0700); err != nil {
		t.Fatal(err)
	}
	suffix, err := randomSuffix(12)
	if err != nil {
		t.Fatal(err)
	}
	fixture := "devenv-engine-test:" + suffix
	// Exercise the production supervisor/wrapper with the same Engine release,
	// without rebuilding the unrelated language toolchains in dev.Dockerfile.
	for _, name := range []string{"devenv-engine", "docker"} {
		data, err := os.ReadFile("../../runtime/" + name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), data, 0755); err != nil {
			t.Fatal(err)
		}
	}
	dockerfile := `FROM docker:29.7.2-dind@sha256:3ef33f2e220b79ed3ef3b99d81746f06f306cd6340e2cb7331d17ae996e74cb6
RUN apk add --no-cache bash curl jq util-linux && mv /usr/local/bin/docker /usr/bin/docker
COPY --chmod=0755 docker /usr/local/bin/docker
COPY --chmod=0755 devenv-engine /usr/local/lib/devenv/devenv-engine
ENTRYPOINT ["/usr/local/lib/devenv/devenv-engine"]
CMD ["sleep", "infinity"]
`
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte(dockerfile), 0600); err != nil {
		t.Fatal(err)
	}
	run("build", "-q", "-t", fixture, dir)
	t.Cleanup(func() { dockerOutput(context.Background(), "image", "rm", fixture) })
	// Register cleanup before creation so partial failures don't leave services.
	t.Cleanup(func() {
		for _, role := range []string{"image-mirror", "build-cache"} {
			dockerOutput(context.Background(), "rm", "-f", cachePrefix(cfg)+"-"+role)
		}
		if err := removeDockerCacheResources(context.Background(), cfg, true); err != nil {
			t.Errorf("cache cleanup: %v", err)
		}
	})
	if err := ensureDockerCaches(ctx, cfg, os.Stdout); err != nil {
		t.Fatal(err)
	}
	if err := ensureDockerCaches(ctx, cfg, os.Stdout); err != nil {
		t.Fatalf("idempotent cache startup: %v", err)
	}
	wt := worktree{CommonDir: "/test-repo/.git"}
	names := []string{"devenv-engine-a-" + suffix, "devenv-engine-b-" + suffix}
	waitForEngine := func(name string) {
		t.Helper()
		for attempt := 0; attempt < 90; attempt++ {
			if _, err := dockerOutput(ctx, "exec", name, "docker", "info"); err == nil {
				return
			}
			time.Sleep(time.Second)
		}
		logs, _ := commandOutput(ctx, "docker", "logs", name)
		t.Fatalf("nested engine did not start: %s", logs)
	}
	start := func(name string) {
		t.Helper()
		rec := worktreeRecord{ID: name}
		args := []string{"run", "-d", "--name", name, "--privileged", "--stop-timeout", "45", "--network", cacheNetwork(cfg),
			"--mount", "type=volume,source=" + engineVolume(cfg, name) + ",target=" + engineDataPath,
			"--tmpfs", "/var/lib/docker"}
		for _, value := range engineEnvironment(wt, rec) {
			args = append(args, "-e", value)
		}
		run(append(args, fixture)...)
		waitForEngine(name)
	}

	for _, name := range names {
		if err := ensureEngineVolume(ctx, cfg, name); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { dockerOutput(context.Background(), "rm", "-f", "-v", name) })
		start(name)
		info := run("exec", name, "docker", "info", "--format", "{{json .RegistryConfig.Mirrors}} {{.DockerRootDir}}")
		if !strings.Contains(info, mirrorAddress) || !strings.Contains(info, engineDataPath) {
			t.Fatalf("wrong inner engine: %s", info)
		}
	}
	a, b := names[0], names[1]
	// A mistakenly reused volume must fail before a second daemon opens it.
	duplicate := "devenv-engine-duplicate-" + suffix
	t.Cleanup(func() { dockerOutput(context.Background(), "rm", "-f", "-v", duplicate) })
	run("run", "-d", "--name", duplicate, "--privileged", "--tmpfs", "/var/lib/docker", "--mount", "type=volume,source="+engineVolume(cfg, a)+",target="+engineDataPath, fixture)
	if exitCode := run("wait", duplicate); exitCode == "0" {
		t.Fatal("a second daemon acquired the same volume")
	}
	// Restart the same container after an abrupt termination, retaining /run
	// files in its writable layer as well as the persistent daemon store.
	run("kill", "--signal", "KILL", a)
	run("start", a)
	waitForEngine(a)
	// The same application port in separate outer network namespaces must work
	// without publishing either workspace's application port on the host engine.
	for _, name := range names {
		network := name + "-ingress"
		run("network", "create", network)
		t.Cleanup(func() {
			dockerOutput(context.Background(), "network", "disconnect", "-f", network, name)
			dockerOutput(context.Background(), "network", "rm", network)
		})
		run("network", "connect", "--alias", "workspace", network, name)
		run("exec", name, "docker", "run", "-d", "--name", "web", "-p", "8080:80", "nginx:alpine")
		body := run("run", "--rm", "--network", network, "--entrypoint", "curl", fixture, "-fsS", "--retry", "10", "--retry-connrefused", "http://workspace:8080")
		if !strings.Contains(body, "Welcome to nginx") {
			t.Fatalf("tunnel-origin response: %s", body)
		}
		ports := run("inspect", name, "--format", "{{json .HostConfig.PortBindings}}")
		if strings.Contains(ports, "8080") {
			t.Fatalf("published application port on host: %s", ports)
		}
	}
	// A first build exports intermediate layers. B has never built this context;
	// its RUN step must be imported from the shared registry rather than executed.
	for _, name := range names {
		run("exec", name, "sh", "-c", "mkdir -p /tmp/build-proof && printf 'FROM alpine:3.22\nRUN echo shared-cache-proof > /proof\n' > /tmp/build-proof/Dockerfile")
		out := run("exec", name, "sh", "-c", "docker build --progress=plain -t cache-proof /tmp/build-proof 2>&1")
		if strings.Contains(out, "error writing layer blob") || strings.Contains(out, "ERROR exporting cache") {
			t.Fatalf("cache export failed: %s", out)
		}
		if name == b {
			step := regexp.MustCompile(`(?m)#([0-9]+) .*RUN echo shared-cache-proof`).FindStringSubmatch(out)
			if len(step) != 2 || !strings.Contains(out, "#"+step[1]+" CACHED") {
				t.Fatalf("second engine did not reuse build layer: %s", out)
			}
		}
		if got := run("exec", name, "docker", "run", "--rm", "cache-proof", "cat", "/proof"); got != "shared-cache-proof" {
			t.Fatalf("build result not loaded into inner engine: %q", got)
		}
	}
	tags := run("exec", b, "curl", "-fsS", "http://"+buildCacheAddress+"/v2/"+buildCacheRepository(wt)+"/tags/list")
	if strings.Count(tags, "cache-") != 2 {
		t.Fatalf("builds overwrote each other's cache manifests: %s", tags)
	}
	// Mirror contents survive registry container replacement; separate volumes
	// hold pull blobs and pushed build manifests.
	mirror := cachePrefix(cfg) + "-image-mirror"
	if got := run("exec", mirror, "sh", "-c", "find /var/lib/registry/docker/registry/v2/blobs -name data | head -1"); got == "" {
		t.Fatal("mirror did not retain downloaded blobs")
	}
	if err := stopAndRemoveContainer(ctx, mirror); err != nil {
		t.Fatal(err)
	}
	if err := ensureDockerCaches(ctx, cfg, os.Stdout); err != nil {
		t.Fatal(err)
	}
	// Full engine state, including user data volumes, survives workspace removal.
	run("exec", a, "docker", "run", "--rm", "-v", "proof-data:/data", "cache-proof", "sh", "-c", "echo persistent > /data/proof")
	if err := stopAndRemoveContainer(ctx, a); err != nil {
		t.Fatal(err)
	}
	start(a)
	if got := run("exec", a, "docker", "run", "--rm", "-v", "proof-data:/data", "cache-proof", "cat", "/data/proof"); got != "persistent" {
		t.Fatalf("lost persistent inner volume: %s", got)
	}
	if got := run("exec", a, "docker", "run", "--rm", "cache-proof", "cat", "/proof"); got != "shared-cache-proof" {
		t.Fatal("lost persisted image")
	}
	fmt.Fprintln(os.Stdout, "Nested ports, mirror storage, cross-engine build cache, and engine recreation verified.")
}
