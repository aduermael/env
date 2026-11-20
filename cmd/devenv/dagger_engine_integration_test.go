package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

// The lines of dev-entrypoint that record the shared engine for the wrapper.
func entrypointDaggerSection(t *testing.T) string {
	t.Helper()
	data, err := os.ReadFile("../../dev.Dockerfile")
	if err != nil {
		t.Fatal(err)
	}
	const start = "rm -f /run/devenv/dagger-engine\n"
	_, rest, ok := strings.Cut(string(data), start)
	if !ok {
		t.Fatal("entrypoint does not reset the shared engine file")
	}
	body, _, ok := strings.Cut(rest, "workspace_env_names=(")
	if !ok {
		t.Fatal("entrypoint section end missing")
	}
	return start + body
}

// Starts the production engine for a temporary root, then runs the pinned CLI
// behind the production wrapper in separate containers that share nothing but
// the root's network. Uses only uniquely named resources; the only bind mount
// is the engine's configuration file in the temporary root.
func TestSharedDaggerEngine(t *testing.T) {
	if os.Getenv("DEVENV_TEST_DAGGER") != "1" {
		t.Skip("set DEVENV_TEST_DAGGER=1 to exercise the shared Dagger engine")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	run := func(args ...string) string {
		t.Helper()
		out, err := dockerOutput(ctx, args...)
		if err != nil {
			t.Fatalf("docker %v: %v", args, err)
		}
		return strings.TrimSpace(out)
	}
	data, err := os.ReadFile("../../dev.Dockerfile")
	if err != nil {
		t.Fatal(err)
	}
	pin := regexp.MustCompile(`(?m)^ARG DAGGER_CLI_VERSION=(\S+)$`).FindStringSubmatch(string(data))
	if len(pin) != 2 {
		t.Fatal("dev.Dockerfile does not pin DAGGER_CLI_VERSION")
	}
	version := pin[1]
	if !strings.Contains(string(data), `LABEL `+daggerLabel+`="${DAGGER_CLI_VERSION}"`) {
		t.Fatal("the image does not name its Dagger release for the shared engine")
	}

	dir := t.TempDir()
	cfg := config{Root: dir, Image: "fixture", DaggerVersion: version}
	if err := os.MkdirAll(filepath.Join(cfg.Root, "run"), 0700); err != nil {
		t.Fatal(err)
	}
	engine, mirror := daggerEngineName(cfg), cachePrefix(cfg)+"-image-mirror"
	t.Cleanup(func() {
		dockerOutput(context.Background(), "rm", "-f", engine, mirror, cachePrefix(cfg)+"-build-cache")
		if err := removeDockerCacheResources(context.Background(), cfg, true); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
	if err := ensureDockerCaches(ctx, cfg, os.Stdout); err != nil {
		t.Fatal(err)
	}
	if err := ensureDaggerEngine(ctx, cfg, true, os.Stdout, os.Stderr); err != nil {
		t.Fatal(err)
	}
	first := run("inspect", engine, "--format", "{{.Id}}")
	for _, replace := range []bool{false, true} {
		if err := ensureDaggerEngine(ctx, cfg, replace, os.Stdout, os.Stderr); err != nil {
			t.Fatalf("idempotent engine startup: %v", err)
		}
	}
	if run("inspect", engine, "--format", "{{.Id}}") != first {
		t.Fatal("an unchanged engine was replaced")
	}
	want := "true always {}"
	if got := run("inspect", engine, "--format", "{{.HostConfig.Privileged}} {{.HostConfig.RestartPolicy.Name}} {{json .HostConfig.PortBindings}}"); got != want {
		t.Fatalf("engine container: %q, want %q", got, want)
	}
	mounts := strings.Split(run("inspect", engine, "--format", `{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} {{.RW}}{{"\n"}}{{end}}`), "\n")
	slices.Sort(mounts)
	if want := []string{"bind  " + daggerConfigPath + " false", "volume " + engine + " " + daggerStatePath + " true"}; !slices.Equal(mounts, want) {
		t.Fatalf("engine mounts: %q, want %q", mounts, want)
	}
	if got := run("exec", engine, "cat", daggerConfigPath); got != string(daggerEngineConfig(cfg)) {
		t.Fatalf("engine configuration: %q", got)
	}
	// Dagger is very slow when its state directory is itself an overlay mount.
	if fs := run("exec", engine, "stat", "-f", "-c", "%T", daggerStatePath); fs == "" || strings.Contains(fs, "overlay") {
		t.Fatalf("engine state is on %q, not on a volume", fs)
	}
	// A second engine cannot be created on the same state volume.
	if _, err := dockerOutput(ctx, daggerEngineArgs(cfg, version, daggerEngineConfig(cfg))...); err == nil {
		t.Fatal("a second engine started on the same volume")
	}

	suffix, err := randomSuffix(12)
	if err != nil {
		t.Fatal(err)
	}
	// The pinned CLI comes from the engine image of the same release. The
	// fixture has no Docker CLI or socket: it cannot start an engine itself.
	fixture := "devenv-dagger-test:" + suffix
	wrapper, err := os.ReadFile("../../runtime/dagger")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dagger"), wrapper, 0755); err != nil {
		t.Fatal(err)
	}
	dockerfile := "FROM debian:bookworm-slim\nCOPY --from=" + daggerEngineImage(version) + " /usr/local/bin/dagger /usr/local/libexec/dagger\nCOPY --chmod=0755 dagger /usr/local/bin/dagger\nWORKDIR /work\n"
	if err := os.WriteFile(filepath.Join(dir, "Dockerfile"), []byte(dockerfile), 0600); err != nil {
		t.Fatal(err)
	}
	run("build", "-q", "-t", fixture, dir)
	t.Cleanup(func() { dockerOutput(context.Background(), "image", "rm", fixture) })
	workspace := func(letter, release string) string {
		t.Helper()
		name := "devenv-dagger-" + letter + "-" + suffix
		t.Cleanup(func() { dockerOutput(context.Background(), "rm", "-f", name) })
		args := []string{"run", "-d", "--name", name, "--network", cacheNetwork(cfg)}
		for _, value := range daggerEnvironment(release) {
			args = append(args, "-e", value)
		}
		run(append(args, fixture, "bash", "-euc", "mkdir -p /run/devenv\n"+entrypointDaggerSection(t)+"exec sleep infinity")...)
		// Without the file the wrapper is the plain CLI: wait for the entrypoint lines.
		for attempt := 0; ; attempt++ {
			if _, err := dockerOutput(ctx, "exec", name, "test", "-s", "/run/devenv/dagger-engine"); err == nil {
				break
			}
			if attempt == 50 {
				t.Fatalf("%s did not record the shared engine", name)
			}
			time.Sleep(100 * time.Millisecond)
		}
		return name
	}
	// env -i: the engine is found without any export in the calling shell.
	dagger := func(name string, env []string, script string, flags ...string) (string, error) {
		args := append([]string{"exec", name, "env", "-i", "PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp", "DEVENV_DAGGER_WAIT=5"}, env...)
		args = append(append(args, "dagger", "--progress=plain"), flags...)
		out, err := dockerOutput(ctx, append(args, "-c", script)...)
		return strings.TrimSpace(out), err
	}
	mustDagger := func(name string, env []string, script string) string {
		t.Helper()
		out, err := dagger(name, env, script)
		if err != nil {
			t.Fatalf("dagger in %s: %v", name, err)
		}
		return out
	}
	// The first run fills a named cache volume and prints a value that only a
	// fresh execution can produce.
	const cache = "container | from alpine:3.22 | with-mounted-cache /cache $(cache-volume devenv-proof)"
	work := cache + ` | with-exec -- sh -c "test -f /cache/token || cat /proc/sys/kernel/random/uuid > /cache/token; cat /cache/token; cat /proc/sys/kernel/random/uuid" | stdout`
	read := cache + ` | with-exec -- cat /cache/token | stdout`

	a, b := workspace("a", version), workspace("b", version)
	warm := mustDagger(a, nil, work)
	token, _, ok := strings.Cut(warm, "\n")
	if !ok || len(token) != 36 {
		t.Fatalf("first run output: %q", warm)
	}
	// Docker Hub downloads go through the root's mirror. alpine can come from
	// the engine image's own content, so another image is pulled.
	if got := mustDagger(a, nil, "container | from busybox:1.37 | with-exec -- echo pulled | stdout"); got != "pulled" {
		t.Fatalf("busybox run: %q", got)
	}
	if catalog := run("exec", mirror, "wget", "-qO-", "http://127.0.0.1:5000/v2/_catalog"); !strings.Contains(catalog, `"library/busybox"`) {
		t.Fatalf("the engine bypassed the mirror: %s", catalog)
	}
	// A stopped mirror leaves Docker Hub itself.
	run("stop", mirror)
	if got := mustDagger(a, nil, "container | from busybox:1.36 | with-exec -- echo pulled | stdout"); got != "pulled" {
		t.Fatalf("busybox run without the mirror: %q", got)
	}
	// B never ran this. The same output means its step came from the engine's
	// cache instead of running again.
	if got := mustDagger(b, nil, work); got != warm {
		t.Fatalf("second workspace ran the step again: %q, first %q", got, warm)
	}
	// A step B does have to run finds what A left in the named cache volume.
	if got := mustDagger(b, nil, read); got != token {
		t.Fatalf("second workspace got another cache volume: %q, want %q", got, token)
	}
	// A hook that pins this release as an engine image lands on the same engine.
	image := daggerEngineImage(version)
	if got := mustDagger(b, []string{"DAGGER_ENGINE=image+docker://" + image}, work); got != warm {
		t.Fatalf("pinned engine image did not use the shared engine: %q", got)
	}
	if got, err := dagger(b, nil, work, "--engine=image+docker://"+image); err != nil || got != warm {
		t.Fatalf("--engine with the pinned image did not use the shared engine: %q %v", got, err)
	}
	refused := func(name string, env, flags []string, reasons ...string) {
		t.Helper()
		started := time.Now()
		out, err := dagger(name, env, read, flags...)
		if err == nil {
			t.Fatalf("dagger ran in %s: %q", name, out)
		}
		for _, reason := range reasons {
			if !strings.Contains(err.Error(), reason) {
				t.Fatalf("error does not say %q: %v", reason, err)
			}
		}
		if waited := time.Since(started); waited > time.Minute {
			t.Fatalf("refusal took %s", waited)
		}
	}
	// Another release is refused: the fixture could not start it, and must not try.
	other := "image+docker://" + daggerEngineRepository + ":v0.0.1"
	refused(b, []string{"DAGGER_ENGINE=" + other}, nil, "second engine", image)
	refused(b, nil, []string{"--engine=" + other}, "second engine", image)
	// A workspace whose CLI is another release than the engine stops with the reason.
	c := workspace("c", "v0.0.1")
	refused(c, nil, nil, "another release", "second engine", "dev down")

	// The state outlives the engine container, as after down --all or a
	// release change, and is opened by one engine at a time.
	if err := stopAndRemoveContainer(ctx, engine); err != nil {
		t.Fatal(err)
	}
	refused(a, nil, nil, "did not answer", "private engine is not started")
	refused(a, nil, []string{"--engine=image+docker://" + image}, "did not answer")
	if err := ensureDaggerEngine(ctx, cfg, false, os.Stdout, os.Stderr); err != nil {
		t.Fatal(err)
	}
	if run("inspect", engine, "--format", "{{.Id}}") == first {
		t.Fatal("engine container was not recreated")
	}
	if got := mustDagger(a, nil, work); got != warm {
		t.Fatalf("engine lost its cache when recreated: %q, want %q", got, warm)
	}
	if engines := strings.Fields(run("ps", "-aq", "--filter", "label="+labelRole+"="+daggerEngineRole, "--filter", "label="+labelRoot+"="+cfg.Root)); len(engines) != 1 {
		t.Fatalf("engines for this root: %v", engines)
	}
	if stale, err := staleDaggerWorkspaces(ctx, cfg, version); err != nil || len(stale) != 0 {
		t.Fatalf("fixtures are not workspaces: %v %v", stale, err)
	}

	// An engine from an older devenv, started with other settings,
	// keeps serving on up and is replaced by setup on the same volume.
	if err := stopAndRemoveContainer(ctx, engine); err != nil {
		t.Fatal(err)
	}
	startOlder := func() string {
		t.Helper()
		if err := writeDaggerEngineConfig(cfg, []byte("{}")); err != nil {
			t.Fatal(err)
		}
		run(daggerEngineArgs(cfg, version, []byte("{}"))...)
		if err := waitForHealthy(ctx, "Dagger engine", engine, daggerReadyTimeout); err != nil {
			t.Fatal(err)
		}
		return run("inspect", engine, "--format", "{{.Id}}")
	}
	settings := func() string { t.Helper(); return run("exec", engine, "cat", daggerConfigPath) }
	older := startOlder()
	var notices bytes.Buffer
	if err := ensureDaggerEngine(ctx, cfg, false, os.Stdout, &notices); err != nil {
		t.Fatal(err)
	}
	if run("inspect", engine, "--format", "{{.Id}}") != older || settings() != "{}" || !strings.Contains(notices.String(), "devenv setup --skip-build") {
		t.Fatalf("up replaced the engine, changed its settings, or did not say how to update it: %q", notices.String())
	}
	if err := ensureDaggerEngine(ctx, cfg, true, os.Stdout, os.Stderr); err != nil {
		t.Fatal(err)
	}
	if run("inspect", engine, "--format", "{{.Id}}") == older || settings() != string(daggerEngineConfig(cfg)) {
		t.Fatal("setup kept the engine with older settings")
	}
	if got := mustDagger(a, nil, work); got != warm {
		t.Fatalf("engine lost its cache when its settings changed: %q, want %q", got, warm)
	}
	// A stopped engine serves no session, so up gives it the new settings.
	if err := stopAndRemoveContainer(ctx, engine); err != nil {
		t.Fatal(err)
	}
	older = startOlder()
	run("stop", engine)
	if err := ensureDaggerEngine(ctx, cfg, false, os.Stdout, os.Stderr); err != nil {
		t.Fatal(err)
	}
	if run("inspect", engine, "--format", "{{.Id}}") == older || settings() != string(daggerEngineConfig(cfg)) {
		t.Fatal("up started a stopped engine with older settings")
	}
	fmt.Fprintln(os.Stdout, "Shared engine, cross-workspace cache reuse, release mismatch, settings change, and state persistence verified.")
}
