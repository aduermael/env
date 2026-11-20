package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testDaggerVersion = "v1.0.0-beta.28"

func TestDaggerEngineIsOnePrivilegedContainerOnOneVolume(t *testing.T) {
	cfg := config{Root: "/Users/me/.devenv"}
	engineConfig := daggerEngineConfig(cfg)
	args := daggerEngineArgs(cfg, testDaggerVersion, engineConfig)
	name := daggerEngineName(cfg)
	for _, pair := range [][2]string{
		{"--name", name},
		{"--restart", "always"},
		{"--network", cacheNetwork(cfg)},
		{"--network-alias", "devenv-dagger"},
		{"--network-alias", "devenv-dagger-v1-0-0-beta-28"},
		{"--mount", "type=volume,source=" + name + ",target=/var/lib/dagger"},
		{"--label", labelRole + "=dagger-engine"},
		{"--label", labelRoot + "=/Users/me/.devenv"},
		{"--label", daggerLabel + "=" + testDaggerVersion},
	} {
		if !containsArgPair(args, pair[0], pair[1]) {
			t.Fatalf("missing %s %s in %v", pair[0], pair[1], args)
		}
	}
	if !slices.Contains(args, "--privileged") {
		t.Fatalf("engine is not privileged: %v", args)
	}
	image := slices.Index(args, "registry.dagger.io/engine:"+testDaggerVersion)
	if image < 0 || strings.Join(args[image+1:], " ") != "--addr unix:///run/dagger/engine.sock --addr tcp://0.0.0.0:1234" {
		t.Fatalf("engine image or listeners: %v", args)
	}
	// Besides its state, the engine sees only its configuration file, read-only.
	configMount := "type=bind,source=" + daggerConfigFile(cfg, engineConfig) + ",target=/etc/dagger/engine.json,readonly"
	if countArgPair(args, "--mount") != 2 || !containsArgPair(args, "--mount", configMount) || !strings.HasPrefix(configMount, "type=bind,source=/Users/me/.devenv/dagger-engine-") {
		t.Fatalf("engine mounts: %v", args)
	}
	for _, arg := range args {
		if arg == "-p" || arg == "--publish" || arg == "-v" || (strings.Contains(arg, "type=bind") && arg != configMount) || strings.Contains(arg, "docker.sock") {
			t.Fatalf("engine exposes host resources: %v", args)
		}
	}

	// One engine and one state volume per root, whatever the release: a
	// second container can never be created on the same volume.
	next := daggerEngineArgs(cfg, "v1.0.0-beta.29", engineConfig)
	if !containsArgPair(next, "--name", name) || !containsArgPair(next, "--mount", "type=volume,source="+name+",target=/var/lib/dagger") {
		t.Fatalf("a new release must reuse the engine name and volume: %v", next)
	}
	if daggerSpec(args) == "" || daggerSpec(args) == daggerSpec(next) {
		t.Fatalf("a new release must be detected as a different engine: %q %q", daggerSpec(args), daggerSpec(next))
	}
	if daggerSpec(args) != daggerSpec(daggerEngineArgs(cfg, testDaggerVersion, daggerEngineConfig(cfg))) {
		t.Fatal("an unchanged engine must not be replaced")
	}
	// Other settings live in another file: a running engine keeps its own.
	older := daggerEngineArgs(cfg, testDaggerVersion, []byte("{}"))
	if daggerSpec(args) == daggerSpec(older) || daggerConfigFile(cfg, []byte("{}")) == daggerConfigFile(cfg, engineConfig) {
		t.Fatal("an engine with other settings must be detected as a different engine")
	}
	if comma := daggerEngineArgs(config{Root: "/Users/me/dev,env"}, testDaggerVersion, engineConfig); !slices.ContainsFunc(comma, func(arg string) bool {
		return strings.HasPrefix(arg, `type=bind,"source=/Users/me/dev,env/dagger-engine-`)
	}) {
		t.Fatalf("a comma in the root splits the mount: %v", comma)
	}
	if other := (config{Root: "/Users/me/other"}); daggerEngineName(other) == name {
		t.Fatal("different roots share an engine volume")
	}
}

// Dagger reads registries from its configuration file; see RegistryConfig in
// the engine's config package.
func TestDaggerEnginePullsDockerHubThroughTheMirror(t *testing.T) {
	var engineConfig struct {
		Registries map[string]struct {
			Mirrors []string `json:"mirrors"`
			HTTP    *bool    `json:"http"`
		} `json:"registries"`
	}
	cfg := config{Root: "/Users/me/.devenv"}
	decoder := json.NewDecoder(bytes.NewReader(daggerEngineConfig(cfg)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&engineConfig); err != nil {
		t.Fatal(err)
	}
	// A dotless name never leaves the engine's resolver.
	address := "devenv-mirror." + cacheNetwork(cfg) + ":5000"
	hub, mirror := engineConfig.Registries["docker.io"], engineConfig.Registries[address]
	if len(engineConfig.Registries) != 2 || !slices.Equal(hub.Mirrors, []string{address}) || hub.HTTP != nil {
		t.Fatalf("registries: %s", daggerEngineConfig(cfg))
	}
	// The mirror has its own entry: without it, it would inherit Docker
	// Hub's settings and be reached over HTTPS.
	if mirror.HTTP == nil || !*mirror.HTTP || len(mirror.Mirrors) != 0 {
		t.Fatalf("mirror is not reached over plain HTTP: %s", daggerEngineConfig(cfg))
	}
}

func TestDaggerEngineAddressFollowsTheRelease(t *testing.T) {
	if got := daggerEngineAddress(testDaggerVersion); got != "tcp://devenv-dagger-v1-0-0-beta-28:1234" {
		t.Fatalf("address = %q", got)
	}
	if daggerEngineHost("v1.0.0-beta.28") == daggerEngineHost("v1.0.0-beta.29") {
		t.Fatal("two releases resolve to the same engine")
	}
	for _, version := range []string{"v1.0.0-beta.28", "v1.0.0", "v2.3.4"} {
		if !daggerVersionPattern.MatchString(version) {
			t.Fatalf("rejected release %q", version)
		}
	}
	// v0.21.9: a CLI from before DAGGER_ENGINE would start its own engine.
	for _, version := range []string{"", "latest", "1.0.0", "v1.0", "v0.21.9", "v1.0.0-beta.28 --privileged", "v1.0.0@sha256:abc", "v1.0.0-beta-28", "v1.0.0-Beta.1", "evil/image:v1.0.0"} {
		if daggerVersionPattern.MatchString(version) {
			t.Fatalf("accepted release %q", version)
		}
		if err := ensureDaggerEngine(context.Background(), config{Root: t.TempDir(), DaggerVersion: version}, true, os.Stdout, os.Stderr); err == nil {
			t.Fatalf("started an engine for release %q", version)
		}
	}
}

func TestWorkspaceUsesSharedDaggerEngineAndKeepsItsDocker(t *testing.T) {
	cfg := config{Image: "local-dev:latest", Root: "/Users/me/.devenv", ProxyContainer: "devenv-dockerproxy", ContainerUser: "dev", DaggerVersion: testDaggerVersion}
	wt := worktree{GitDir: "/Users/me/src/env/.git", CommonDir: "/Users/me/src/env/.git", RepoRoot: "/Users/me/src/env", CheckoutPath: "/Users/me/src/env"}
	rec := worktreeRecord{ID: "env-root-a1b2c3", Port: 43100}
	args := workspaceRunArgs(cfg, wt, rec, 501, 20)
	for name, want := range map[string]string{
		"DAGGER_ENGINE":              "tcp://devenv-dagger-v1-0-0-beta-28:1234",
		"DEVENV_DAGGER_ENGINE_IMAGE": "registry.dagger.io/engine:v1.0.0-beta.28",
		"DOCKER_HOST":                "unix:///var/run/docker.sock",
	} {
		if got, ok := envValue(args, name); !ok || got != want {
			t.Fatalf("%s = %q (present=%v), want %q", name, got, ok, want)
		}
	}
	if !containsArgPair(args, "--label", daggerWorkspaceLabel+"="+testDaggerVersion) {
		t.Fatalf("workspace does not record its Dagger release: %v", args)
	}
	// Containers inherit image labels. A workspace started without the shared
	// engine must not look as if it had one.
	dockerfile, err := os.ReadFile("../../dev.Dockerfile")
	if err != nil {
		t.Fatal(err)
	}
	if daggerWorkspaceLabel == daggerLabel || strings.Contains(string(dockerfile), daggerWorkspaceLabel) {
		t.Fatal("the image sets the label that marks a workspace on the shared engine")
	}
	if !containsArgPair(args, "--network", cacheNetwork(cfg)) {
		t.Fatalf("workspace cannot reach the engine's network: %v", args)
	}
	// Only the Dagger runner moved out: the private daemon and its
	// exclusively locked volume stay.
	if !slices.Contains(args, "--privileged") || !containsArgPair(args, "--mount", "type=volume,source="+engineVolume(cfg, rec.ID)+",target="+engineDataPath) {
		t.Fatalf("workspace lost its private Docker engine: %v", args)
	}
	for _, arg := range args {
		if strings.Contains(arg, daggerStatePath) || strings.Contains(arg, daggerEngineName(cfg)) {
			t.Fatalf("workspace mounts the engine's state: %v", args)
		}
	}

	cfg.DaggerVersion = ""
	if _, ok := envValue(workspaceRunArgs(cfg, wt, rec, 501, 20), "DAGGER_ENGINE"); ok {
		t.Fatal("DAGGER_ENGINE set without a shared engine")
	}
}

// The entrypoint gives the wrapper the engine address in a file, and removes
// a stale one when devenv passes no shared engine.
func TestEntrypointRecordsSharedDaggerEngine(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash required for entrypoint fixture")
	}
	state := filepath.Join(t.TempDir(), "dagger-engine")
	script := strings.ReplaceAll(entrypointDaggerSection(t), "/run/devenv/dagger-engine", state)
	run := func(env ...string) {
		t.Helper()
		shell := exec.Command("bash", "-euo", "pipefail", "-c", script)
		shell.Env = append([]string{"PATH=" + os.Getenv("PATH")}, env...)
		if out, err := shell.CombinedOutput(); err != nil {
			t.Fatalf("entrypoint section: %s %v", out, err)
		}
	}
	run(daggerEnvironment(testDaggerVersion)...)
	got, err := os.ReadFile(state)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "tcp://devenv-dagger-v1-0-0-beta-28:1234\nregistry.dagger.io/engine:v1.0.0-beta.28\n" {
		t.Fatalf("shared engine file = %q", got)
	}
	run("DAGGER_ENGINE=cloud")
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatalf("stale shared engine file kept: %v", err)
	}
}

func TestDaggerWrapper(t *testing.T) {
	for _, command := range []string{"bash", "timeout"} {
		if _, err := exec.LookPath(command); err != nil {
			t.Skipf("Linux runtime wrapper needs %s", command)
		}
	}
	// Run the real wrapper. Only the CLI binary, the state file and name
	// resolution are substituted; the engine port is a real listener.
	dir := t.TempDir()
	script, err := os.ReadFile("../../runtime/dagger")
	if err != nil {
		t.Fatal(err)
	}
	stub := filepath.Join(dir, "real-dagger")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nprintf 'engine=%s\\n' \"${DAGGER_ENGINE-unset}\"\nprintf '%s\\n' \"$@\"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(dir, "dagger-engine")
	text := strings.Replace(string(script), "real=/usr/local/libexec/dagger", "real="+stub, 1)
	text = strings.Replace(text, "state=/run/devenv/dagger-engine", "state="+state, 1)
	if strings.Count(text, stub) != 1 || strings.Count(text, state) != 1 || !strings.Contains(text, "any_release="+daggerEngineAlias+"\n") {
		t.Fatal("wrapper paths or engine alias changed")
	}
	wrapper := filepath.Join(dir, "dagger")
	if err := os.WriteFile(wrapper, []byte(text), 0755); err != nil {
		t.Fatal(err)
	}
	// Names listed in RESOLVES exist; every other name does not.
	getent := "#!/bin/sh\nfor name in $RESOLVES; do [ \"$name\" = \"$2\" ] && exit 0; done\nexit 2\n"
	if err := os.WriteFile(filepath.Join(dir, "getent"), []byte(getent), 0755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	shared := "tcp://127.0.0.1:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	image := daggerEngineImage(testDaggerVersion)
	const up, otherRelease, down = "127.0.0.1", "devenv-dagger", ""

	run := func(resolves string, env []string, args ...string) (string, error) {
		t.Helper()
		cmd := exec.Command(wrapper, args...)
		cmd.Env = append([]string{"PATH=" + dir + string(os.PathListSeparator) + os.Getenv("PATH"), "RESOLVES=" + resolves, "DEVENV_DAGGER_WAIT=0"}, env...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	expect := func(resolves string, env []string, args []string, want string) {
		t.Helper()
		out, err := run(resolves, env, args...)
		if err != nil || out != want {
			t.Fatalf("dagger %v (env %v): %v\n got: %q\nwant: %q", args, env, err, out, want)
		}
	}
	refuse := func(resolves string, env []string, args []string, reasons ...string) {
		t.Helper()
		out, err := run(resolves, env, args...)
		if err == nil || strings.Contains(out, "engine=") {
			t.Fatalf("dagger %v (env %v) reached the CLI: %q", args, env, out)
		}
		for _, reason := range reasons {
			if !strings.Contains(out, reason) {
				t.Fatalf("dagger %v: error does not say %q: %q", args, reason, out)
			}
		}
	}

	// Without a shared engine the image behaves as the plain CLI.
	expect(up, nil, []string{"check"}, "engine=unset\ncheck\n")

	if err := os.WriteFile(state, []byte(shared+"\n"+image+"\n"), 0644); err != nil {
		t.Fatal(err)
	}
	// No per-shell export is needed, and a session value is kept.
	expect(up, nil, []string{"check"}, "engine="+shared+"\ncheck\n")
	expect(up, []string{"DAGGER_ENGINE=" + shared}, []string{"check", "ui"}, "engine="+shared+"\ncheck\nui\n")
	// A hook that pins the same release as an image runs on the shared engine.
	expect(up, nil, []string{"check", "--engine=image+docker://" + image}, "engine=unset\ncheck\n--engine="+shared+"\n")
	expect(up, nil, []string{"--engine", "image://" + image + "@sha256:abc", "check"}, "engine=unset\n--engine\n"+shared+"\ncheck\n")
	expect(up, []string{"DAGGER_ENGINE=docker-image://" + image}, []string{"check"}, "engine="+shared+"\ncheck\n")
	// Another release is never started as a second engine.
	other := "registry.dagger.io/engine:v1.0.0-beta.25"
	refuse(up, nil, []string{"check", "--engine=image+docker://" + other}, other, image, "second engine", "DEVENV_SHARED_DAGGER=0")
	refuse(up, []string{"DAGGER_ENGINE=image://" + other}, []string{"check"}, "second engine")
	// Engines the caller names stay the caller's choice, even while the shared one is down.
	expect(down, nil, []string{"check", "--engine=cloud"}, "engine=unset\ncheck\n--engine=cloud\n")
	expect(down, nil, []string{"check", "--cloud"}, "engine=unset\ncheck\n--cloud\n")
	expect(down, nil, []string{"check", "--cloud=1"}, "engine=unset\ncheck\n--cloud=1\n")
	// The session's DAGGER_ENGINE must not hide the older variables, which
	// the CLI ranks below it.
	session := "DAGGER_ENGINE=" + shared
	expect(down, []string{session, "DAGGER_CLOUD_ENGINE=1"}, []string{"check"}, "engine=cloud\ncheck\n")
	expect(down, []string{session, "_EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://builder"}, []string{"check"}, "engine=ssh://builder\ncheck\n")
	expect(up, []string{session, "_EXPERIMENTAL_DAGGER_RUNNER_HOST=docker-image://" + image}, []string{"check"}, "engine="+shared+"\ncheck\n")
	refuse(up, []string{session, "_EXPERIMENTAL_DAGGER_RUNNER_HOST=docker-image://" + other}, []string{"check"}, "second engine")
	expect(down, []string{"DAGGER_ENGINE=cloud", "_EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://builder"}, []string{"check"}, "engine=cloud\ncheck\n")
	expect(down, nil, []string{"--engine", "tcp://elsewhere:1234", "check"}, "engine=unset\n--engine\ntcp://elsewhere:1234\ncheck\n")
	expect(down, []string{"DAGGER_ENGINE=ssh://builder"}, []string{"check"}, "engine=ssh://builder\ncheck\n")
	// Function arguments are not engine flags.
	expect(up, nil, []string{"call", "build", "--", "--engine=image://" + other}, "engine="+shared+"\ncall\nbuild\n--\n--engine=image://"+other+"\n")
	// A CLI and an engine of different releases stop with the reason.
	refuse(otherRelease, nil, []string{"check"}, image, "another release", "second engine", "dev down")
	refuse(otherRelease, nil, []string{"check", "--engine=image+docker://" + image}, "another release")
	// An engine that is down fails at once instead of after the CLI's ten minutes.
	refuse(down, nil, []string{"check"}, "did not answer", shared, "private engine is not started")
	listener.Close()
	refuse(up, nil, []string{"check"}, "did not answer")
	// Commands that need no engine run while it is down, and still never
	// point at a private one. Help for checks is loaded through an engine.
	for _, args := range [][]string{{"version"}, {"--help"}, {"help", "engine"}, {"completion", "bash"}, {"login"}} {
		expect(down, nil, args, "engine="+shared+"\n"+strings.Join(args, "\n")+"\n")
		expect(otherRelease, nil, args, "engine="+shared+"\n"+strings.Join(args, "\n")+"\n")
	}
	refuse(down, nil, []string{"check", "--help"}, "did not answer")
	// Shell completion does not wait for the engine.
	started := time.Now()
	if out, err := run(down, []string{"DEVENV_DAGGER_WAIT=30"}, "__complete", "check", ""); err == nil || time.Since(started) > 10*time.Second {
		t.Fatalf("completion waited %s for the engine: %q", time.Since(started), out)
	}
	// The opt-out leaves the CLI alone and drops the session's engine, so
	// the CLI starts its own. A value the caller set is kept.
	optOut := "DEVENV_SHARED_DAGGER=0"
	expect(down, []string{optOut}, []string{"check", "--engine=image+docker://" + other}, "engine=unset\ncheck\n--engine=image+docker://"+other+"\n")
	expect(down, []string{optOut, session}, []string{"check"}, "engine=unset\ncheck\n")
	expect(down, []string{optOut, "DAGGER_ENGINE=cloud"}, []string{"check"}, "engine=cloud\ncheck\n")

	if err := os.WriteFile(state, []byte("cloud\n"), 0644); err != nil {
		t.Fatal(err)
	}
	refuse(up, nil, []string{"check"}, "dev down")
}
