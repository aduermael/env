package main

import (
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Fixtures. Each helper returns symlink-resolved paths so expectations match
// what resolveWorktree reports on macOS, where the temp directory is a
// symlink into /private.

func resolved(t *testing.T, path string) string {
	t.Helper()
	out, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func mkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	mkdir(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// mkRepo creates <base>/<name> with a .git directory.
func mkRepo(t *testing.T, base, name string) string {
	t.Helper()
	repo := filepath.Join(base, name)
	mkdir(t, filepath.Join(repo, ".git", "refs"))
	writeFile(t, filepath.Join(repo, ".git", "HEAD"), "ref: refs/heads/main\n")
	return resolved(t, repo)
}

// mkLinked creates <repo>/worktrees/<name> whose .git file points at
// <repo>/.git/worktrees/<gitDirName> with a relative gitdir and commondir.
func mkLinked(t *testing.T, repo, name, gitDirName string) string {
	t.Helper()
	checkout := filepath.Join(repo, "worktrees", name)
	gitDir := filepath.Join(repo, ".git", "worktrees", gitDirName)
	mkdir(t, checkout)
	mkdir(t, gitDir)
	writeFile(t, filepath.Join(checkout, ".git"), "gitdir: ../../.git/worktrees/"+gitDirName+"\n")
	writeFile(t, filepath.Join(gitDir, "commondir"), "../..\n")
	writeFile(t, filepath.Join(gitDir, "gitdir"), filepath.Join(checkout, ".git")+"\n")
	return checkout
}

func TestResolveWorktreeMainCheckout(t *testing.T) {
	base := t.TempDir()
	repo := mkRepo(t, base, "env")
	mkdir(t, filepath.Join(repo, "cmd", "devenv"))

	for _, start := range []string{repo, filepath.Join(repo, "cmd", "devenv")} {
		wt, err := resolveWorktree(start)
		if err != nil {
			t.Fatalf("resolve %s: %v", start, err)
		}
		if wt.GitDir != filepath.Join(repo, ".git") {
			t.Fatalf("GitDir = %q, want %q", wt.GitDir, filepath.Join(repo, ".git"))
		}
		if wt.CommonDir != wt.GitDir {
			t.Fatalf("CommonDir = %q, want %q", wt.CommonDir, wt.GitDir)
		}
		if wt.RepoRoot != repo {
			t.Fatalf("RepoRoot = %q, want %q", wt.RepoRoot, repo)
		}
		if wt.Name != "" {
			t.Fatalf("Name = %q, want empty", wt.Name)
		}
		if wt.PaneDir() != "/workspace" {
			t.Fatalf("PaneDir = %q, want /workspace", wt.PaneDir())
		}
		if wt.RepoSlug() != "env" || wt.WorktreeSlug() != "root" {
			t.Fatalf("slugs = %q/%q, want env/root", wt.RepoSlug(), wt.WorktreeSlug())
		}
	}
}

func TestResolveWorktreeLinkedUsesCheckoutName(t *testing.T) {
	base := t.TempDir()
	repo := mkRepo(t, base, "env")
	// git appended a number to the gitdir name; the checkout name wins.
	checkout := mkLinked(t, repo, "feature", "feature1")
	mkdir(t, filepath.Join(checkout, "pkg"))

	for _, start := range []string{checkout, filepath.Join(checkout, "pkg")} {
		wt, err := resolveWorktree(start)
		if err != nil {
			t.Fatalf("resolve %s: %v", start, err)
		}
		if wt.GitDir != filepath.Join(repo, ".git", "worktrees", "feature1") {
			t.Fatalf("GitDir = %q", wt.GitDir)
		}
		if wt.CommonDir != filepath.Join(repo, ".git") {
			t.Fatalf("CommonDir = %q", wt.CommonDir)
		}
		if wt.RepoRoot != repo {
			t.Fatalf("RepoRoot = %q, want %q", wt.RepoRoot, repo)
		}
		if wt.Name != "feature" {
			t.Fatalf("Name = %q, want feature", wt.Name)
		}
		if wt.PaneDir() != "/workspace/worktrees/feature" {
			t.Fatalf("PaneDir = %q", wt.PaneDir())
		}
		if !filepath.IsAbs(wt.GitDir) || !filepath.IsAbs(wt.CommonDir) {
			t.Fatal("registry keys must be absolute")
		}
	}
}

func TestResolveWorktreeLinkedWithAbsoluteGitdir(t *testing.T) {
	base := t.TempDir()
	repo := mkRepo(t, base, "env")
	checkout := mkLinked(t, repo, "feature", "feature")
	writeFile(t, filepath.Join(checkout, ".git"), "gitdir: "+filepath.Join(repo, ".git", "worktrees", "feature")+"\n")

	wt, err := resolveWorktree(checkout)
	if err != nil {
		t.Fatal(err)
	}
	if wt.Name != "feature" || wt.RepoRoot != repo {
		t.Fatalf("got %+v", wt)
	}
}

func TestResolveWorktreeLinkedOutsideWorktreesDirFails(t *testing.T) {
	base := t.TempDir()
	repo := mkRepo(t, base, "env")
	gitDir := filepath.Join(repo, ".git", "worktrees", "feature")
	mkdir(t, gitDir)
	writeFile(t, filepath.Join(gitDir, "commondir"), "../..\n")
	checkout := filepath.Join(base, "elsewhere", "feature")
	mkdir(t, checkout)
	writeFile(t, filepath.Join(checkout, ".git"), "gitdir: "+gitDir+"\n")

	_, err := resolveWorktree(checkout)
	if err == nil {
		t.Fatal("expected an error for a linked worktree outside <repo>/worktrees")
	}
	want := filepath.Join(repo, "worktrees", "feature")
	if !strings.Contains(err.Error(), want) {
		t.Fatalf("error %q does not name %s", err, want)
	}
}

func TestResolveWorktreeSubmoduleUsesEnclosingWorktree(t *testing.T) {
	base := t.TempDir()
	repo := mkRepo(t, base, "env")
	mkdir(t, filepath.Join(repo, ".git", "modules", "vendor"))
	writeFile(t, filepath.Join(repo, "vendor", ".git"), "gitdir: ../.git/modules/vendor\n")
	mkdir(t, filepath.Join(repo, "vendor", "src"))

	wt, err := resolveWorktree(filepath.Join(repo, "vendor", "src"))
	if err != nil {
		t.Fatal(err)
	}
	if wt.GitDir != filepath.Join(repo, ".git") || wt.Name != "" {
		t.Fatalf("submodule in main checkout resolved to %+v", wt)
	}

	checkout := mkLinked(t, repo, "feature", "feature1")
	mkdir(t, filepath.Join(repo, ".git", "worktrees", "feature1", "modules", "vendor"))
	writeFile(t, filepath.Join(checkout, "vendor", ".git"), "gitdir: ../../../.git/worktrees/feature1/modules/vendor\n")

	wt, err = resolveWorktree(filepath.Join(checkout, "vendor"))
	if err != nil {
		t.Fatal(err)
	}
	if wt.Name != "feature" || wt.GitDir != filepath.Join(repo, ".git", "worktrees", "feature1") {
		t.Fatalf("submodule in linked worktree resolved to %+v", wt)
	}
}

func TestResolveWorktreeThroughSymlinkedParent(t *testing.T) {
	base := t.TempDir()
	repo := mkRepo(t, filepath.Join(base, "real"), "env")
	checkout := mkLinked(t, repo, "feature", "feature")
	alias := filepath.Join(base, "alias")
	if err := os.Symlink(filepath.Join(base, "real"), alias); err != nil {
		t.Fatal(err)
	}

	direct, err := resolveWorktree(checkout)
	if err != nil {
		t.Fatal(err)
	}
	viaAlias, err := resolveWorktree(filepath.Join(alias, "env", "worktrees", "feature"))
	if err != nil {
		t.Fatal(err)
	}
	if direct != viaAlias {
		t.Fatalf("symlinked path resolved differently:\n%+v\n%+v", direct, viaAlias)
	}

	mainDirect, err := resolveWorktree(repo)
	if err != nil {
		t.Fatal(err)
	}
	mainAlias, err := resolveWorktree(filepath.Join(alias, "env"))
	if err != nil {
		t.Fatal(err)
	}
	if mainDirect != mainAlias {
		t.Fatalf("symlinked main checkout resolved differently:\n%+v\n%+v", mainDirect, mainAlias)
	}
}

func TestResolveWorktreeOutsideGitFails(t *testing.T) {
	base := t.TempDir()
	mkdir(t, filepath.Join(base, "plain", "dir"))
	if _, err := resolveWorktree(filepath.Join(base, "plain", "dir")); err == nil {
		t.Fatal("expected an error outside a git worktree")
	}
}

func TestSanitizeSlug(t *testing.T) {
	cases := map[string]string{
		"env":                                 "env",
		"Feature/Auth Flow":                   "feature-auth-flow",
		"--weird__name--":                     "weird-name",
		"":                                    "wt",
		"!!!":                                 "wt",
		"a-very-long-worktree-name-that-goes": "a-very-long-worktree-nam",
	}
	for in, want := range cases {
		if got := sanitizeSlug(in, "wt"); got != want {
			t.Errorf("sanitizeSlug(%q) = %q, want %q", in, got, want)
		}
	}
	if got := sanitizeSlug("", "repo"); got != "repo" {
		t.Errorf("empty slug fallback = %q, want repo", got)
	}
}

func TestMintMachineIDRetriesOnCollision(t *testing.T) {
	wt := worktree{RepoRoot: "/x/Env", Name: "Feature Auth"}
	suffixes := []string{"aaaaaa", "bbbbbb"}
	suffix := func(int) (string, error) {
		s := suffixes[0]
		suffixes = suffixes[1:]
		return s, nil
	}
	taken := func(id string) bool { return id == "env-feature-auth-aaaaaa" }
	id, err := mintMachineID(wt, taken, suffix)
	if err != nil {
		t.Fatal(err)
	}
	if id != "env-feature-auth-bbbbbb" {
		t.Fatalf("id = %q", id)
	}
	if containerName(id) != "devenv-env-feature-auth-bbbbbb" {
		t.Fatalf("container name = %q", containerName(id))
	}
}

func TestRegistryKeepsIDAndPortPerWorktree(t *testing.T) {
	path := filepath.Join(t.TempDir(), "herdr", "worktrees.json")
	reg, err := loadRegistry(path)
	if err != nil {
		t.Fatal(err)
	}
	main := worktree{GitDir: "/r/.git", CommonDir: "/r/.git", RepoRoot: "/r", CheckoutPath: "/r"}
	linked := worktree{GitDir: "/r/.git/worktrees/f", CommonDir: "/r/.git", RepoRoot: "/r", CheckoutPath: "/r/worktrees/f", Name: "f"}

	first, changed, err := reg.ensureRecord(main, nil, nil)
	if err != nil || !changed {
		t.Fatalf("first ensure: changed=%v err=%v", changed, err)
	}
	if err := saveRegistry(path, reg); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("registry mode = %o, want 600", info.Mode().Perm())
	}

	reloaded, err := loadRegistry(path)
	if err != nil {
		t.Fatal(err)
	}
	again, changed, err := reloaded.ensureRecord(main, nil, nil)
	if err != nil || changed {
		t.Fatalf("second ensure: changed=%v err=%v", changed, err)
	}
	if again.ID != first.ID || again.Port != first.Port {
		t.Fatalf("record changed: %+v vs %+v", again, first)
	}
	if again.WorktreePath != "/r" || again.GitCommonDir != "/r/.git" {
		t.Fatalf("record = %+v", again)
	}

	second, changed, err := reloaded.ensureRecord(linked, nil, nil)
	if err != nil || !changed {
		t.Fatalf("linked ensure: changed=%v err=%v", changed, err)
	}
	if second.ID == first.ID || second.Port == first.Port {
		t.Fatalf("linked worktree reused id or port: %+v vs %+v", second, first)
	}
	if !strings.HasPrefix(second.ID, "r-f-") || !strings.HasPrefix(first.ID, "r-root-") {
		t.Fatalf("ids = %q, %q", first.ID, second.ID)
	}
}

func TestAllocatePortSkipsUsedReservedAndBusy(t *testing.T) {
	used := map[int]bool{portRangeStart: true}
	reserved := map[int]bool{portRangeStart + 1: true}
	busy := map[int]bool{portRangeStart + 2: true}
	port, err := allocatePort(used, reserved, func(p int) bool { return !busy[p] })
	if err != nil {
		t.Fatal(err)
	}
	if port != portRangeStart+3 {
		t.Fatalf("port = %d, want %d", port, portRangeStart+3)
	}
}

func TestProxyPortReservedCoversMovedProxyPort(t *testing.T) {
	reserved := proxyPortReserved(config{ProxyPort: "43150"})
	if !reserved[43150] {
		t.Fatal("expected the proxy port to be reserved")
	}
}

func TestLoopbackPortFreeDetectsListener(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	if loopbackPortFree(port) {
		t.Fatalf("port %d has a listener but was reported free", port)
	}
	listener.Close()
	if !loopbackPortFree(port) {
		t.Fatalf("port %d was released but is reported busy", port)
	}
}

func TestRenderSSHConfig(t *testing.T) {
	records := []worktreeRecord{
		{ID: "env-root-a1b2c3", Port: 43107},
		{ID: "env-feature-c4d5e6", Port: 43108},
	}
	got := renderSSHConfig("dev", "/Users/me/.ssh/devenv_herdr_ed25519", "/Users/me/.devenv/herdr/known_hosts", records)
	for _, want := range []string{
		"Host devenv-*\n  User dev\n  IdentityFile /Users/me/.ssh/devenv_herdr_ed25519\n  IdentitiesOnly yes\n  UserKnownHostsFile /Users/me/.devenv/herdr/known_hosts\n  StrictHostKeyChecking accept-new\n",
		"Host devenv-env-root-a1b2c3\n  HostName 127.0.0.1\n  Port 43107\n",
		"Host devenv-env-feature-c4d5e6\n  HostName 127.0.0.1\n  Port 43108\n",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("ssh_config missing %q:\n%s", want, got)
		}
	}
	if strings.Count(got, "Host devenv-*") != 1 {
		t.Fatalf("expected one shared block:\n%s", got)
	}
}

func TestUpsertTopBlockInsertsThenReplaces(t *testing.T) {
	existing := "Host github.com\n  User git\n"
	block := "# >>> devenv herdr >>>\nInclude /a/ssh_config\n# <<< devenv herdr <<<\n"

	next, changed, err := upsertTopBlock(existing, sshConfigStartMarker, sshConfigEndMarker, block)
	if err != nil || !changed {
		t.Fatalf("insert: changed=%v err=%v", changed, err)
	}
	if !strings.HasPrefix(next, block) {
		t.Fatalf("block is not at the top:\n%s", next)
	}
	if !strings.HasSuffix(next, existing) {
		t.Fatalf("existing lines changed:\n%s", next)
	}

	same, changed, err := upsertTopBlock(next, sshConfigStartMarker, sshConfigEndMarker, block)
	if err != nil || changed || same != next {
		t.Fatalf("rewrite: changed=%v err=%v\n%s", changed, err, same)
	}

	moved := "# >>> devenv herdr >>>\nInclude /b/ssh_config\n# <<< devenv herdr <<<\n"
	replaced, changed, err := upsertTopBlock(next, sshConfigStartMarker, sshConfigEndMarker, moved)
	if err != nil || !changed {
		t.Fatalf("replace: changed=%v err=%v", changed, err)
	}
	if strings.Count(replaced, "Include ") != 1 || !strings.Contains(replaced, "/b/ssh_config") {
		t.Fatalf("block was not replaced in place:\n%s", replaced)
	}
	if !strings.HasSuffix(replaced, existing) {
		t.Fatalf("existing lines changed:\n%s", replaced)
	}
}

func TestRemoveBlockLeavesOtherLines(t *testing.T) {
	text := "# top comment\n# >>> devenv herdr >>>\nInclude /a/ssh_config\n# <<< devenv herdr <<<\n\nHost github.com\n  User git\n"
	next, changed, err := removeBlock(text, sshConfigStartMarker, sshConfigEndMarker)
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	if next != "# top comment\nHost github.com\n  User git\n" {
		t.Fatalf("unexpected result:\n%q", next)
	}
	same, changed, err := removeBlock(next, sshConfigStartMarker, sshConfigEndMarker)
	if err != nil || changed || same != next {
		t.Fatalf("second remove: changed=%v err=%v", changed, err)
	}
	if _, _, err := removeBlock("# >>> devenv herdr >>>\n", sshConfigStartMarker, sshConfigEndMarker); err == nil {
		t.Fatal("expected an error for an incomplete block")
	}
}

func TestWriteSSHConfigsAndDeleteData(t *testing.T) {
	base := t.TempDir()
	cfg := config{
		Root:          filepath.Join(base, "devenv"),
		UserSSHDir:    filepath.Join(base, "ssh"),
		ContainerUser: "dev",
	}
	writeFile(t, filepath.Join(cfg.UserSSHDir, "config"), "Host github.com\n  User git\n")
	reg := &registry{Version: 1, Worktrees: map[string]*worktreeRecord{
		"/r/.git": {ID: "r-root-abc123", Port: 43100},
	}}

	if err := writeSSHConfigs(cfg, reg, io.Discard); err != nil {
		t.Fatal(err)
	}
	userConfig, err := os.ReadFile(filepath.Join(cfg.UserSSHDir, "config"))
	if err != nil {
		t.Fatal(err)
	}
	wantInclude := "Include " + filepath.Join(cfg.Root, "herdr", "ssh_config")
	if !strings.HasPrefix(string(userConfig), sshConfigStartMarker+"\n"+wantInclude+"\n"+sshConfigEndMarker+"\n") {
		t.Fatalf("include block missing or not at top:\n%s", userConfig)
	}
	if !strings.HasSuffix(string(userConfig), "Host github.com\n  User git\n") {
		t.Fatalf("existing lines changed:\n%s", userConfig)
	}
	rendered, err := os.ReadFile(filepath.Join(cfg.Root, "herdr", "ssh_config"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(rendered), "Host devenv-r-root-abc123\n  HostName 127.0.0.1\n  Port 43100\n") {
		t.Fatalf("rendered ssh_config:\n%s", rendered)
	}

	if err := removeSSHInclude(cfg, io.Discard); err != nil {
		t.Fatal(err)
	}
	userConfig, err = os.ReadFile(filepath.Join(cfg.UserSSHDir, "config"))
	if err != nil {
		t.Fatal(err)
	}
	if string(userConfig) != "Host github.com\n  User git\n" {
		t.Fatalf("after delete-data:\n%q", userConfig)
	}
}

func TestEnsureHerdrKeysLeavesExistingKeys(t *testing.T) {
	base := t.TempDir()
	cfg := config{
		Root:       filepath.Join(base, "devenv"),
		UserSSHDir: filepath.Join(base, "ssh"),
	}
	calls := 0
	keygen := func(privateKey string) error {
		calls++
		writeFile(t, privateKey, "private "+filepath.Base(privateKey)+"\n")
		writeFile(t, privateKey+".pub", "public "+filepath.Base(privateKey)+"\n")
		return nil
	}

	if err := ensureHerdrKeys(cfg, io.Discard, io.Discard, keygen); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("keygen calls = %d, want 2", calls)
	}
	clientKey := filepath.Join(cfg.UserSSHDir, "devenv_herdr_ed25519")
	info, err := os.Stat(clientKey)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("client key mode = %o, want 600", info.Mode().Perm())
	}
	authorized, err := os.ReadFile(filepath.Join(cfg.Root, "herdr", "id_ed25519.pub"))
	if err != nil {
		t.Fatal(err)
	}
	if string(authorized) != "public devenv_herdr_ed25519\n" {
		t.Fatalf("authorized key = %q", authorized)
	}
	if _, err := os.Stat(filepath.Join(cfg.Root, "herdr", "ssh_host_ed25519_key.pub")); err != nil {
		t.Fatal(err)
	}

	if err := ensureHerdrKeys(cfg, io.Discard, io.Discard, keygen); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("keygen ran again: calls = %d", calls)
	}
	if err := ensureHerdrKeys(cfg, io.Discard, io.Discard, func(string) error { return errors.New("must not run") }); err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceRunArgs(t *testing.T) {
	cfg := config{
		Image:          "local-dev:latest",
		Root:           "/Users/me/.devenv",
		ProxyContainer: "devenv-dockerproxy",
		ContainerUser:  "dev",
	}
	wt := worktree{
		GitDir:       "/Users/me/src/env/.git/worktrees/feature",
		CommonDir:    "/Users/me/src/env/.git",
		RepoRoot:     "/Users/me/src/env",
		CheckoutPath: "/Users/me/src/env/worktrees/feature",
		Name:         "feature",
	}
	rec := worktreeRecord{ID: "env-feature-c4d5e6", Port: 43108}
	args := workspaceRunArgs(cfg, wt, rec, 501, 20)

	if args[0] != "run" || args[1] != "-d" {
		t.Fatalf("args start with %v", args[:2])
	}
	for _, arg := range args {
		if arg == "--rm" || arg == "-it" {
			t.Fatalf("unexpected %s in args", arg)
		}
	}
	pairs := [][2]string{
		{"--restart", "unless-stopped"},
		{"--name", "devenv-env-feature-c4d5e6"},
		{"--label", labelRole + "=workspace"},
		{"--label", labelRoot + "=/Users/me/.devenv"},
		{"--label", labelWorktreeGitDir + "=/Users/me/src/env/.git/worktrees/feature"},
		{"--label", labelMachineID + "=env-feature-c4d5e6"},
		{"--network", "devenv-dockerproxy-net"},
		{"-p", "127.0.0.1:43108:22"},
		{"-v", "/Users/me/src/env:/workspace"},
		{"-v", "/Users/me/src/env:/Users/me/src/env"},
		{"--mount", "type=bind,source=/Users/me/.devenv,target=/devenv,readonly"},
		{"--mount", "type=bind,source=/Users/me/.devenv/home,target=/home/dev"},
		{"--mount", "type=bind,source=/Users/me/.devenv/ssh,target=/home/dev/.ssh"},
		{"--mount", "type=volume,source=devenv-herdr-env-feature-c4d5e6,target=/var/lib/devenv/herdr"},
		{"--mount", "type=volume,source=devenv-dockerproxy-codex-sqlite,target=/var/lib/codex-sqlite"},
	}
	for _, pair := range pairs {
		if !containsArgPair(args, pair[0], pair[1]) {
			t.Fatalf("missing %s %s in %v", pair[0], pair[1], args)
		}
	}
	env := map[string]string{
		"DEVENV_PANE_CWD":   "/workspace/worktrees/feature",
		"LOCAL_USER_ID":     "501",
		"LOCAL_GROUP_ID":    "20",
		"LOCAL_USER_NAME":   "dev",
		"DOCKER_HOST":       "tcp://devenv-dockerproxy:2375",
		"GIT_CONFIG_GLOBAL": "/devenv/gitconfig",
		"CODEX_SQLITE_HOME": "/var/lib/codex-sqlite",
	}
	for name, want := range env {
		got, ok := envValue(args, name)
		if !ok || got != want {
			t.Fatalf("%s = %q (present=%v), want %q", name, got, ok, want)
		}
	}
	if args[len(args)-1] != "local-dev:latest" {
		t.Fatalf("image is not last: %v", args)
	}

	atWorkspace := worktree{GitDir: "/workspace/.git", CommonDir: "/workspace/.git", RepoRoot: "/workspace", CheckoutPath: "/workspace"}
	args = workspaceRunArgs(cfg, atWorkspace, rec, 501, 20)
	if !containsArgPair(args, "-v", "/workspace:/workspace") || countArgPair(args, "-v") != 1 {
		t.Fatalf("expected a single bind for a repo at /workspace: %v", args)
	}
}

func TestZshrcDevFunctionAcceptsOnlyUpAndDown(t *testing.T) {
	block := zshrcBlock(config{Root: "/Users/me/.devenv", Image: "local-dev:latest", ProxyImage: "p", ProxyContainer: "c", ProxyPort: "23750"})
	for _, want := range []string{"devenv up --quiet", "devenv stop --quiet", "usage: dev up|down"} {
		if !strings.Contains(block, want) {
			t.Fatalf("zshrc block missing %q:\n%s", want, block)
		}
	}
	if strings.Contains(block, "devenv run") {
		t.Fatalf("zshrc block still calls devenv run:\n%s", block)
	}
}

func TestHerdrMachineRegisteredMatchesTargetNotLabel(t *testing.T) {
	machines := []herdrMachine{{ID: "x", Label: "renamed", Target: "devenv-env-root-a1b2c3", Session: "default", Enabled: true}}
	if !herdrMachineRegistered(machines, "env-root-a1b2c3") {
		t.Fatal("expected the alias target to match")
	}
	if herdrMachineRegistered([]herdrMachine{{Label: "env-root-a1b2c3", Target: "other"}}, "env-root-a1b2c3") {
		t.Fatal("a matching label alone must not count")
	}
	want := []string{"machine", "add", "devenv-env-root-a1b2c3", "--label", "env-root-a1b2c3", "--remote-session", "default"}
	if got := herdrMachineAddArgs("env-root-a1b2c3"); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("machine add args = %v", got)
	}
}

func containsArgPair(args []string, flag, value string) bool {
	for i, arg := range args {
		if arg == flag && i+1 < len(args) && args[i+1] == value {
			return true
		}
	}
	return false
}

func countArgPair(args []string, flag string) int {
	n := 0
	for _, arg := range args {
		if arg == flag {
			n++
		}
	}
	return n
}

func envValue(args []string, name string) (string, bool) {
	prefix := name + "="
	for i, arg := range args {
		if arg != "-e" || i+1 >= len(args) {
			continue
		}
		value := args[i+1]
		if strings.HasPrefix(value, prefix) {
			return strings.TrimPrefix(value, prefix), true
		}
	}
	return "", false
}
