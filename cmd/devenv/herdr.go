package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	labelWorktreeGitDir = "com.aduermael.env.devenv.worktree-gitdir"
	labelMachineID      = "com.aduermael.env.devenv.machine-id"

	sshConfigStartMarker = "# >>> devenv herdr >>>"
	sshConfigEndMarker   = "# <<< devenv herdr <<<"

	registryVersion = 1
	portRangeStart  = 43100
	portRangeEnd    = 43999
	slugMaxLength   = 24
	machineIDSuffix = 6

	containerSSHPort     = "22"
	containerWorkspace   = "/workspace"
	herdrVolumeTarget    = "/var/lib/devenv/herdr"
	herdrRemoteSession   = "default"
	readyCheckTimeout    = 30 * time.Second
	defaultContainerUser = "dev"
)

// worktree describes the git worktree a dev container belongs to.
type worktree struct {
	// GitDir is the absolute, symlink-resolved git directory. It is the
	// registry key: <repo>/.git for the main checkout, or
	// <repo>/.git/worktrees/<gitdir-name> for a linked worktree.
	GitDir string
	// CommonDir is the main .git directory.
	CommonDir string
	// RepoRoot is the parent of CommonDir. It is the bind mount source.
	RepoRoot string
	// CheckoutPath is the resolved directory that holds the .git entry.
	CheckoutPath string
	// Name is "" for the main checkout and <name> for <repo>/worktrees/<name>.
	Name string
}

// PaneDir is where Herdr panes start inside the container.
func (wt worktree) PaneDir() string {
	if wt.Name == "" {
		return containerWorkspace
	}
	return containerWorkspace + "/worktrees/" + wt.Name
}

// RepoSlug is the sanitized directory name of the main checkout.
func (wt worktree) RepoSlug() string {
	return sanitizeSlug(filepath.Base(wt.RepoRoot), "repo")
}

// WorktreeSlug is "root" for the main checkout and the sanitized <name>
// otherwise.
func (wt worktree) WorktreeSlug() string {
	if wt.Name == "" {
		return "root"
	}
	return sanitizeSlug(wt.Name, "wt")
}

// resolveWorktree walks up from start to find the enclosing git worktree. It
// does not run git. Symlinks are resolved before the walk and on every path
// that ends up in the result, so two spellings of one checkout resolve to one
// registry key.
func resolveWorktree(start string) (worktree, error) {
	dir, err := filepath.Abs(start)
	if err != nil {
		return worktree{}, fmt.Errorf("resolve %s: %w", start, err)
	}
	dir, err = filepath.EvalSymlinks(dir)
	if err != nil {
		return worktree{}, fmt.Errorf("resolve %s: %w", start, err)
	}

	for {
		dotGit := filepath.Join(dir, ".git")
		info, err := os.Stat(dotGit)
		switch {
		case err == nil && info.IsDir():
			return mainWorktree(dir, dotGit)
		case err == nil:
			wt, submodule, err := linkedWorktree(dir, dotGit)
			if err != nil {
				return worktree{}, err
			}
			if !submodule {
				return wt, nil
			}
		case !errors.Is(err, os.ErrNotExist):
			return worktree{}, fmt.Errorf("stat %s: %w", dotGit, err)
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return worktree{}, fmt.Errorf("%s is not inside a git worktree; run dev up from a checkout", start)
		}
		dir = parent
	}
}

func mainWorktree(dir, dotGit string) (worktree, error) {
	gitDir, err := filepath.EvalSymlinks(dotGit)
	if err != nil {
		return worktree{}, fmt.Errorf("resolve %s: %w", dotGit, err)
	}
	root, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return worktree{}, fmt.Errorf("resolve %s: %w", dir, err)
	}
	return worktree{
		GitDir:       gitDir,
		CommonDir:    gitDir,
		RepoRoot:     root,
		CheckoutPath: root,
	}, nil
}

// linkedWorktree reads a .git file. The second result is true when the file
// belongs to a submodule, which means the walk has to continue upward.
func linkedWorktree(dir, dotGit string) (worktree, bool, error) {
	data, err := os.ReadFile(dotGit)
	if err != nil {
		return worktree{}, false, fmt.Errorf("read %s: %w", dotGit, err)
	}
	gitDirValue, ok := gitdirLine(string(data))
	if !ok {
		return worktree{}, false, fmt.Errorf("%s does not contain a gitdir: line", dotGit)
	}
	gitDir := gitDirValue
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(dir, gitDir)
	}
	gitDir, err = filepath.EvalSymlinks(gitDir)
	if err != nil {
		return worktree{}, false, fmt.Errorf("resolve gitdir %s from %s: %w", gitDirValue, dotGit, err)
	}

	if isSubmoduleGitDir(gitDir) {
		return worktree{}, true, nil
	}

	commonData, err := os.ReadFile(filepath.Join(gitDir, "commondir"))
	if err != nil {
		return worktree{}, false, fmt.Errorf("%s is not a linked worktree: read commondir: %w", dir, err)
	}
	commonDir := strings.TrimSpace(string(commonData))
	if !filepath.IsAbs(commonDir) {
		commonDir = filepath.Join(gitDir, commonDir)
	}
	commonDir, err = filepath.EvalSymlinks(commonDir)
	if err != nil {
		return worktree{}, false, fmt.Errorf("resolve commondir for %s: %w", dir, err)
	}

	worktreesDir := filepath.Join(commonDir, "worktrees")
	if !isUnder(gitDir, worktreesDir) {
		return worktree{}, false, fmt.Errorf("git directory %s is not under %s", gitDir, worktreesDir)
	}

	checkout, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return worktree{}, false, fmt.Errorf("resolve %s: %w", dir, err)
	}
	repoRoot := filepath.Dir(commonDir)
	name := filepath.Base(checkout)
	expected := filepath.Join(repoRoot, "worktrees", name)
	if checkout != expected {
		return worktree{}, false, fmt.Errorf("linked worktree %s must live at %s; devenv only supports worktrees under %s", checkout, expected, filepath.Join(repoRoot, "worktrees"))
	}

	return worktree{
		GitDir:       gitDir,
		CommonDir:    commonDir,
		RepoRoot:     repoRoot,
		CheckoutPath: checkout,
		Name:         name,
	}, false, nil
}

func gitdirLine(text string) (string, bool) {
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "gitdir:") {
			value := strings.TrimSpace(strings.TrimPrefix(line, "gitdir:"))
			if value != "" {
				return value, true
			}
		}
	}
	return "", false
}

// isSubmoduleGitDir reports whether gitDir is <.git>/modules/<name> or, for
// a submodule checked out inside a linked worktree,
// <.git>/worktrees/<x>/modules/<name>.
func isSubmoduleGitDir(gitDir string) bool {
	parts := strings.Split(filepath.ToSlash(gitDir), "/")
	for i := 0; i+1 < len(parts); i++ {
		if parts[i] != ".git" {
			continue
		}
		if parts[i+1] == "modules" {
			return true
		}
		if parts[i+1] == "worktrees" && i+3 < len(parts) && parts[i+3] == "modules" {
			return true
		}
	}
	return false
}

func isUnder(path, parent string) bool {
	rel, err := filepath.Rel(parent, path)
	if err != nil {
		return false
	}
	return rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// sanitizeSlug lowercases value, keeps [a-z0-9-], collapses dashes, trims
// them, and caps the result. An empty result becomes fallback.
func sanitizeSlug(value, fallback string) string {
	var b strings.Builder
	lastDash := true
	for _, r := range strings.ToLower(value) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			lastDash = false
		default:
			if !lastDash {
				b.WriteByte('-')
				lastDash = true
			}
		}
	}
	slug := strings.Trim(b.String(), "-")
	if len(slug) > slugMaxLength {
		slug = strings.Trim(slug[:slugMaxLength], "-")
	}
	if slug == "" {
		return fallback
	}
	return slug
}

func randomSuffix(n int) (string, error) {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate machine id: %w", err)
	}
	for i := range buf {
		buf[i] = alphabet[int(buf[i])%len(alphabet)]
	}
	return string(buf), nil
}

// mintMachineID builds <repo-slug>-<worktree-slug>-<suffix> and retries while
// taken reports the id as used.
func mintMachineID(wt worktree, taken func(id string) bool, suffix func(int) (string, error)) (string, error) {
	prefix := wt.RepoSlug() + "-" + wt.WorktreeSlug() + "-"
	for attempt := 0; attempt < 100; attempt++ {
		s, err := suffix(machineIDSuffix)
		if err != nil {
			return "", err
		}
		id := prefix + s
		if !taken(id) {
			return id, nil
		}
	}
	return "", errors.New("could not find a free machine id")
}

func containerName(id string) string {
	return "devenv-" + id
}

func herdrVolumeName(id string) string {
	return "devenv-herdr-" + id
}

// registry is ~/.devenv/herdr/worktrees.json.
type registry struct {
	Version   int                        `json:"version"`
	Worktrees map[string]*worktreeRecord `json:"worktrees"`
}

type worktreeRecord struct {
	ID           string `json:"id"`
	Port         int    `json:"port"`
	WorktreePath string `json:"worktree_path"`
	GitCommonDir string `json:"git_common_dir"`
}

func herdrDir(cfg config) string {
	return filepath.Join(cfg.Root, "herdr")
}

func registryPath(cfg config) string {
	return filepath.Join(herdrDir(cfg), "worktrees.json")
}

func registryLockPath(cfg config) string {
	return filepath.Join(herdrDir(cfg), "worktrees.lock")
}

func loadRegistry(path string) (*registry, error) {
	reg := &registry{Version: registryVersion, Worktrees: map[string]*worktreeRecord{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return reg, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read registry %s: %w", path, err)
	}
	if err := json.Unmarshal(data, reg); err != nil {
		return nil, fmt.Errorf("parse registry %s: %w", path, err)
	}
	if reg.Version != registryVersion {
		return nil, fmt.Errorf("registry %s has version %d; this devenv supports version %d", path, reg.Version, registryVersion)
	}
	if reg.Worktrees == nil {
		reg.Worktrees = map[string]*worktreeRecord{}
	}
	return reg, nil
}

func saveRegistry(path string, reg *registry) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create registry directory: %w", err)
	}
	data, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		return fmt.Errorf("encode registry: %w", err)
	}
	data = append(data, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write registry: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("write registry: %w", err)
	}
	return nil
}

func (reg *registry) hasID(id string) bool {
	for _, rec := range reg.Worktrees {
		if rec.ID == id {
			return true
		}
	}
	return false
}

func (reg *registry) usedPorts() map[int]bool {
	used := map[int]bool{}
	for _, rec := range reg.Worktrees {
		used[rec.Port] = true
	}
	return used
}

func (reg *registry) sortedRecords() []worktreeRecord {
	out := make([]worktreeRecord, 0, len(reg.Worktrees))
	for _, rec := range reg.Worktrees {
		out = append(out, *rec)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// ensureRecord returns the registry row for wt, minting an id and allocating
// a port on first use. It reports whether the registry changed.
func (reg *registry) ensureRecord(wt worktree, reserved map[int]bool, portFree func(int) bool) (*worktreeRecord, bool, error) {
	if rec, ok := reg.Worktrees[wt.GitDir]; ok {
		return rec, false, nil
	}
	id, err := mintMachineID(wt, reg.hasID, randomSuffix)
	if err != nil {
		return nil, false, err
	}
	port, err := allocatePort(reg.usedPorts(), reserved, portFree)
	if err != nil {
		return nil, false, err
	}
	rec := &worktreeRecord{
		ID:           id,
		Port:         port,
		WorktreePath: wt.CheckoutPath,
		GitCommonDir: wt.CommonDir,
	}
	reg.Worktrees[wt.GitDir] = rec
	return rec, true, nil
}

// allocatePort picks the first port in the range that is not in the registry,
// not reserved, and that portFree reports as available.
func allocatePort(used, reserved map[int]bool, portFree func(int) bool) (int, error) {
	for port := portRangeStart; port <= portRangeEnd; port++ {
		if used[port] || reserved[port] {
			continue
		}
		if portFree != nil && !portFree(port) {
			continue
		}
		return port, nil
	}
	return 0, fmt.Errorf("no free port between %d and %d", portRangeStart, portRangeEnd)
}

// loopbackPortFree binds and releases the port, then dials it. Go listeners
// set SO_REUSEADDR, and on macOS a loopback bind can succeed while another
// process listens on 0.0.0.0, so the dial is what catches that listener.
func loopbackPortFree(port int) bool {
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return false
	}
	_ = listener.Close()
	conn, err := net.DialTimeout("tcp", address, 200*time.Millisecond)
	if err == nil {
		_ = conn.Close()
		return false
	}
	return true
}

func proxyPortReserved(cfg config) map[int]bool {
	reserved := map[int]bool{}
	if port, err := strconv.Atoi(cfg.ProxyPort); err == nil {
		reserved[port] = true
	}
	return reserved
}

// SSH material on the Mac.

func herdrClientKeyPath(cfg config) string {
	return filepath.Join(cfg.UserSSHDir, "devenv_herdr_ed25519")
}

func herdrHostKeyPath(cfg config) string {
	return filepath.Join(herdrDir(cfg), "ssh_host_ed25519_key")
}

func herdrAuthorizedKeyPath(cfg config) string {
	return filepath.Join(herdrDir(cfg), "id_ed25519.pub")
}

func herdrSSHConfigPath(cfg config) string {
	return filepath.Join(herdrDir(cfg), "ssh_config")
}

func herdrKnownHostsPath(cfg config) string {
	return filepath.Join(herdrDir(cfg), "known_hosts")
}

func userSSHConfigPath(cfg config) string {
	return filepath.Join(cfg.UserSSHDir, "config")
}

// ensureHerdrKeys creates the client key and the container host key once.
// Existing keys are never replaced.
func ensureHerdrKeys(cfg config, stdout, stderr io.Writer, keygen func(privateKey string) error) error {
	if err := os.MkdirAll(cfg.UserSSHDir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", cfg.UserSSHDir, err)
	}
	if err := os.MkdirAll(herdrDir(cfg), 0o700); err != nil {
		return fmt.Errorf("create %s: %w", herdrDir(cfg), err)
	}

	clientKey := herdrClientKeyPath(cfg)
	if !fileExists(clientKey) {
		if err := keygen(clientKey); err != nil {
			return fmt.Errorf("generate Herdr client key: %w", err)
		}
		status(cfg, stdout, "create: Herdr client key %s", displayPath(clientKey))
	} else {
		status(cfg, stdout, "ok: Herdr client key exists")
	}
	if err := os.Chmod(clientKey, 0o600); err != nil {
		return fmt.Errorf("chmod Herdr client key: %w", err)
	}
	if !fileExists(clientKey + ".pub") {
		return fmt.Errorf("Herdr client public key %s.pub is missing; move the private key aside to regenerate both", clientKey)
	}
	if err := copyFile(clientKey+".pub", herdrAuthorizedKeyPath(cfg), 0o644); err != nil {
		return fmt.Errorf("install Herdr authorized key: %w", err)
	}

	hostKey := herdrHostKeyPath(cfg)
	if !fileExists(hostKey) {
		if err := keygen(hostKey); err != nil {
			return fmt.Errorf("generate Herdr host key: %w", err)
		}
		status(cfg, stdout, "create: Herdr host key")
	} else {
		status(cfg, stdout, "ok: Herdr host key exists")
	}
	if err := os.Chmod(hostKey, 0o600); err != nil {
		return fmt.Errorf("chmod Herdr host key: %w", err)
	}
	if !fileExists(hostKey + ".pub") {
		return fmt.Errorf("Herdr host public key %s.pub is missing; move the private key aside to regenerate both", hostKey)
	}
	return nil
}

func sshKeygen(privateKey string) error {
	bin, err := exec.LookPath("ssh-keygen")
	if err != nil {
		return errors.New("ssh-keygen not found")
	}
	cmd := exec.Command(bin, "-q", "-t", "ed25519", "-N", "", "-C", "devenv-herdr", "-f", privateKey)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// renderSSHConfig produces ~/.devenv/herdr/ssh_config from the registry.
func renderSSHConfig(user, identityFile, knownHosts string, records []worktreeRecord) string {
	var b strings.Builder
	b.WriteString("# Managed by devenv. Rewritten on every dev up.\n")
	b.WriteString("Host devenv-*\n")
	fmt.Fprintf(&b, "  User %s\n", user)
	fmt.Fprintf(&b, "  IdentityFile %s\n", identityFile)
	b.WriteString("  IdentitiesOnly yes\n")
	fmt.Fprintf(&b, "  UserKnownHostsFile %s\n", knownHosts)
	b.WriteString("  StrictHostKeyChecking accept-new\n")
	for _, rec := range records {
		b.WriteString("\n")
		fmt.Fprintf(&b, "Host %s\n", containerName(rec.ID))
		b.WriteString("  HostName 127.0.0.1\n")
		fmt.Fprintf(&b, "  Port %d\n", rec.Port)
	}
	return b.String()
}

func sshIncludeBlock(cfg config) string {
	return strings.Join([]string{
		sshConfigStartMarker,
		"Include " + herdrSSHConfigPath(cfg),
		sshConfigEndMarker,
		"",
	}, "\n")
}

// managedBlock locates a marker-delimited block. end is just past the end
// marker's line terminator; blankEnd is past any blank lines after it.
type managedBlock struct {
	start, end, blankEnd int
}

func findManagedBlock(text, startMarker, endMarker string) (managedBlock, bool, error) {
	start := strings.Index(text, startMarker)
	end := strings.Index(text, endMarker)
	if (start == -1) != (end == -1) {
		return managedBlock{}, false, fmt.Errorf("found incomplete managed block (%s)", startMarker)
	}
	if start == -1 {
		return managedBlock{}, false, nil
	}
	if end < start {
		return managedBlock{}, false, fmt.Errorf("found malformed managed block (%s)", startMarker)
	}
	end += len(endMarker)
	if end < len(text) && text[end] == '\r' {
		end++
	}
	if end < len(text) && text[end] == '\n' {
		end++
	}
	blankEnd := end
	for blankEnd < len(text) && (text[blankEnd] == '\n' || text[blankEnd] == '\r') {
		blankEnd++
	}
	return managedBlock{start: start, end: end, blankEnd: blankEnd}, true, nil
}

// upsertTopBlock replaces an existing block in place or inserts the block at
// the top of the text. Lines outside the block are left alone.
func upsertTopBlock(text, startMarker, endMarker, block string) (string, bool, error) {
	block = strings.TrimRight(block, "\n") + "\n"
	found, ok, err := findManagedBlock(text, startMarker, endMarker)
	if err != nil {
		return "", false, err
	}
	if ok {
		next := text[:found.start] + block + text[found.end:]
		return next, next != text, nil
	}
	next := block
	if text != "" {
		next += "\n" + text
	}
	return next, true, nil
}

// removeBlock removes the marker-delimited block and the blank lines after
// it, and leaves every other line.
func removeBlock(text, startMarker, endMarker string) (string, bool, error) {
	found, ok, err := findManagedBlock(text, startMarker, endMarker)
	if err != nil {
		return "", false, err
	}
	if !ok {
		return text, false, nil
	}
	return text[:found.start] + text[found.blankEnd:], true, nil
}

// writeSSHConfigs renders ~/.devenv/herdr/ssh_config and installs the include
// block at the top of ~/.ssh/config.
func writeSSHConfigs(cfg config, reg *registry, stdout io.Writer) error {
	content := renderSSHConfig(cfg.ContainerUser, herdrClientKeyPath(cfg), herdrKnownHostsPath(cfg), reg.sortedRecords())
	if err := os.MkdirAll(herdrDir(cfg), 0o700); err != nil {
		return fmt.Errorf("create %s: %w", herdrDir(cfg), err)
	}
	if err := os.WriteFile(herdrSSHConfigPath(cfg), []byte(content), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", herdrSSHConfigPath(cfg), err)
	}

	if err := os.MkdirAll(cfg.UserSSHDir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", cfg.UserSSHDir, err)
	}
	path := userSSHConfigPath(cfg)
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read %s: %w", path, err)
	}
	next, changed, err := upsertTopBlock(string(data), sshConfigStartMarker, sshConfigEndMarker, sshIncludeBlock(cfg))
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	if !changed {
		status(cfg, stdout, "ok: ssh config include is current")
		return nil
	}
	if err := os.WriteFile(path, []byte(next), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	status(cfg, stdout, "update: Herdr include in %s", displayPath(path))
	return nil
}

func removeSSHInclude(cfg config, stdout io.Writer) error {
	path := userSSHConfigPath(cfg)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	next, changed, err := removeBlock(string(data), sshConfigStartMarker, sshConfigEndMarker)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	if !changed {
		return nil
	}
	if err := os.WriteFile(path, []byte(next), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	status(cfg, stdout, "remove: Herdr include from %s", displayPath(path))
	return nil
}

// Container lifecycle.

// workspaceRunArgs builds the docker run command for a worktree container.
func workspaceRunArgs(cfg config, wt worktree, rec worktreeRecord, uid, gid int) []string {
	args := []string{
		"run", "-d",
		"--restart", "unless-stopped",
		"--name", containerName(rec.ID),
		"--label", labelManaged + "=true",
		"--label", labelRole + "=workspace",
		"--label", labelRoot + "=" + cfg.Root,
		"--label", labelWorktreeGitDir + "=" + wt.GitDir,
		"--label", labelMachineID + "=" + rec.ID,
		"--network", proxyNetworkName(cfg),
		"-p", net.JoinHostPort("127.0.0.1", strconv.Itoa(rec.Port)) + ":" + containerSSHPort,
		"-e", "DEVENV_PANE_CWD=" + wt.PaneDir(),
		"-e", "LOCAL_USER_ID=" + strconv.Itoa(uid),
		"-e", "LOCAL_GROUP_ID=" + strconv.Itoa(gid),
		"-e", "LOCAL_USER_NAME=" + cfg.ContainerUser,
		"-e", "DOCKER_HOST=tcp://" + cfg.ProxyContainer + ":2375",
		"-e", "GIT_CONFIG_GLOBAL=/devenv/gitconfig",
		"-v", wt.RepoRoot + ":" + containerWorkspace,
	}
	if wt.RepoRoot != containerWorkspace {
		args = append(args, "-v", wt.RepoRoot+":"+wt.RepoRoot)
	}
	args = append(args,
		"--mount", "type=bind,source="+cfg.Root+",target=/devenv,readonly",
		"--mount", "type=bind,source="+filepath.Join(cfg.Root, "home")+",target=/home/"+cfg.ContainerUser,
		"--mount", "type=bind,source="+filepath.Join(cfg.Root, "ssh")+",target=/home/"+cfg.ContainerUser+"/.ssh",
		"--mount", "type=volume,source="+herdrVolumeName(rec.ID)+",target="+herdrVolumeTarget,
		"--mount", "type=volume,source="+codexSqliteVolumeName(cfg)+",target="+codexSqliteHome,
		"-e", "CODEX_SQLITE_HOME="+codexSqliteHome,
		cfg.Image,
	)
	return args
}

func ensureHerdrVolume(ctx context.Context, cfg config, id string) error {
	if _, err := dockerOutput(ctx, "volume", "inspect", herdrVolumeName(id)); err == nil {
		return nil
	} else if !isDockerNotFound(err) {
		return fmt.Errorf("inspect Herdr volume: %w", err)
	}
	if _, err := dockerOutput(ctx, "volume", "create",
		"--label", labelManaged+"=true",
		"--label", labelRole+"=herdr",
		"--label", labelRoot+"="+cfg.Root,
		"--label", labelMachineID+"="+id,
		herdrVolumeName(id),
	); err != nil {
		return fmt.Errorf("create Herdr volume: %w", err)
	}
	return nil
}

// findWorktreeContainer returns the container labeled for this worktree and
// root, if any.
func findWorktreeContainer(ctx context.Context, cfg config, wt worktree) (string, containerInspect, bool, error) {
	out, err := dockerOutput(ctx, "ps", "-aq",
		"--filter", "label="+labelManaged+"=true",
		"--filter", "label="+labelRoot+"="+cfg.Root,
		"--filter", "label="+labelWorktreeGitDir+"="+wt.GitDir,
	)
	if err != nil {
		return "", containerInspect{}, false, fmt.Errorf("list worktree containers: %w", err)
	}
	ids := strings.Fields(out)
	if len(ids) == 0 {
		return "", containerInspect{}, false, nil
	}
	info, exists, err := inspectContainer(ctx, ids[0])
	if err != nil {
		return "", containerInspect{}, false, fmt.Errorf("inspect worktree container: %w", err)
	}
	if !exists {
		return "", containerInspect{}, false, nil
	}
	return ids[0], info, true, nil
}

func ownsWorktree(info containerInspect, cfg config, wt worktree) bool {
	labels := info.Config.Labels
	return labels[labelManaged] == "true" &&
		labels[labelRole] == "workspace" &&
		labels[labelRoot] == cfg.Root &&
		labels[labelWorktreeGitDir] == wt.GitDir
}

func up(ctx context.Context, cfg config, stdout, stderr io.Writer) error {
	if err := ensureMacOS(); err != nil {
		return err
	}
	status(cfg, stdout, "check: Docker CLI and daemon")
	if err := dockerCheck(ctx); err != nil {
		return err
	}
	if err := ensureLayout(cfg, stdout); err != nil {
		return err
	}
	if err := ensureGitconfig(cfg, stdout); err != nil {
		return err
	}
	if err := ensureSSH(cfg, stdout, stderr); err != nil {
		return err
	}
	if err := ensureHerdrKeys(cfg, stdout, stderr, sshKeygen); err != nil {
		return err
	}
	hostSocket, err := hostDockerSocket(cfg)
	if err != nil {
		return err
	}
	cfg.HostSocket = hostSocket
	if err := ensureProxy(ctx, cfg, hostSocket, stdout, stderr); err != nil {
		return err
	}

	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("find current directory: %w", err)
	}
	wt, err := resolveWorktree(cwd)
	if err != nil {
		return err
	}

	rec, created, err := ensureWorkspaceContainer(ctx, cfg, wt, stdout, stderr)
	if err != nil {
		return err
	}

	if created {
		status(cfg, stdout, "wait: ssh to %s", containerName(rec.ID))
		if err := waitForSSH(ctx, cfg, rec.ID, readyCheckTimeout); err != nil {
			name := containerName(rec.ID)
			notice(stderr, "container %s did not answer ssh within %s: %v", name, readyCheckTimeout, err)
			notice(stderr, "inspect it with: docker logs %s", name)
			_ = dockerRun(ctx, io.Discard, io.Discard, "rm", "-f", name)
			return fmt.Errorf("workspace container %s is not reachable; it was removed", name)
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		home = ""
	}
	herdrBin, _ := exec.LookPath("herdr")
	hcBin, _ := lookupHC(exec.LookPath, home)
	registerHerdrMachines(ctx, cfg, rec.ID, herdrBin, hcBin, stdout, stderr)
	status(cfg, stdout, "done: %s is up for %s", containerName(rec.ID), wt.CheckoutPath)
	return nil
}

// ensureWorkspaceContainer runs the create-or-attach decision under the
// registry lock. It reports whether a container was created.
func ensureWorkspaceContainer(ctx context.Context, cfg config, wt worktree, stdout, stderr io.Writer) (worktreeRecord, bool, error) {
	if err := os.MkdirAll(herdrDir(cfg), 0o700); err != nil {
		return worktreeRecord{}, false, fmt.Errorf("create %s: %w", herdrDir(cfg), err)
	}
	unlock, err := lockFile(registryLockPath(cfg))
	if err != nil {
		return worktreeRecord{}, false, fmt.Errorf("lock registry: %w", err)
	}
	defer unlock()

	reg, err := loadRegistry(registryPath(cfg))
	if err != nil {
		return worktreeRecord{}, false, err
	}
	recPtr, changed, err := reg.ensureRecord(wt, proxyPortReserved(cfg), loopbackPortFree)
	if err != nil {
		return worktreeRecord{}, false, err
	}
	rec := *recPtr
	if changed {
		if err := saveRegistry(registryPath(cfg), reg); err != nil {
			return worktreeRecord{}, false, err
		}
		status(cfg, stdout, "register: %s on port %d", rec.ID, rec.Port)
	}
	if err := writeSSHConfigs(cfg, reg, stdout); err != nil {
		return worktreeRecord{}, false, err
	}

	name := containerName(rec.ID)
	existingID, info, exists, err := findWorktreeContainer(ctx, cfg, wt)
	if err != nil {
		return worktreeRecord{}, false, err
	}
	if exists && info.State.Running {
		status(cfg, stdout, "ok: %s is running", name)
		return rec, false, nil
	}
	if exists {
		status(cfg, stdout, "remove: stopped container for this worktree")
		if err := dockerRun(ctx, io.Discard, stderrFor(cfg, stderr), "rm", "-f", existingID); err != nil {
			return worktreeRecord{}, false, fmt.Errorf("remove stopped worktree container: %w", err)
		}
	}

	if other, exists, err := inspectContainer(ctx, name); err != nil {
		return worktreeRecord{}, false, fmt.Errorf("inspect %s: %w", name, err)
	} else if exists && !ownsWorktree(other, cfg, wt) {
		return worktreeRecord{}, false, fmt.Errorf("container name %s belongs to something else; remove it or delete the row for %s in %s", name, wt.GitDir, registryPath(cfg))
	} else if exists {
		if err := dockerRun(ctx, io.Discard, stderrFor(cfg, stderr), "rm", "-f", name); err != nil {
			return worktreeRecord{}, false, fmt.Errorf("remove stopped %s: %w", name, err)
		}
	}

	if !loopbackPortFree(rec.Port) {
		notice(stderr, "port %d is recorded for %s but another process listens on it", rec.Port, wt.GitDir)
		notice(stderr, "free that port, or delete the row for %s in %s to allocate a new one", wt.GitDir, registryPath(cfg))
		return worktreeRecord{}, false, fmt.Errorf("port %d for %s is busy", rec.Port, name)
	}

	if err := ensureHerdrVolume(ctx, cfg, rec.ID); err != nil {
		return worktreeRecord{}, false, err
	}

	status(cfg, stdout, "start: %s", name)
	args := workspaceRunArgs(cfg, wt, rec, os.Getuid(), os.Getgid())
	if _, err := dockerOutput(ctx, args...); err != nil {
		winner, exists, inspectErr := inspectContainer(ctx, name)
		if inspectErr == nil && exists && ownsWorktree(winner, cfg, wt) {
			status(cfg, stdout, "ok: %s was started by another dev up", name)
			return rec, false, nil
		}
		if inspectErr == nil && exists {
			return worktreeRecord{}, false, fmt.Errorf("container name %s belongs to something else: %w", name, err)
		}
		return worktreeRecord{}, false, fmt.Errorf("start %s: %w", name, err)
	}
	return rec, true, nil
}

func stop(ctx context.Context, cfg config, stdout, stderr io.Writer) error {
	status(cfg, stdout, "check: Docker CLI and daemon")
	if err := dockerCheck(ctx); err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("find current directory: %w", err)
	}
	wt, err := resolveWorktree(cwd)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(herdrDir(cfg), 0o700); err != nil {
		return fmt.Errorf("create %s: %w", herdrDir(cfg), err)
	}
	unlock, err := lockFile(registryLockPath(cfg))
	if err != nil {
		return fmt.Errorf("lock registry: %w", err)
	}
	defer unlock()

	id, _, exists, err := findWorktreeContainer(ctx, cfg, wt)
	if err != nil {
		return err
	}
	if !exists {
		status(cfg, stdout, "ok: no container for %s", wt.CheckoutPath)
		return nil
	}
	status(cfg, stdout, "remove: container for %s", wt.CheckoutPath)
	if err := dockerRun(ctx, io.Discard, stderrFor(cfg, stderr), "rm", "-f", id); err != nil {
		return fmt.Errorf("remove worktree container: %w", err)
	}
	status(cfg, stdout, "done: %s is down", wt.CheckoutPath)
	return nil
}

// waitForSSH retries ssh through the managed alias until it answers. The
// alias uses accept-new, so this also records the host key.
func waitForSSH(ctx context.Context, cfg config, id string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		cmd := exec.CommandContext(ctx, "ssh",
			"-F", userSSHConfigPath(cfg),
			"-o", "BatchMode=yes",
			"-o", "ConnectTimeout=3",
			containerName(id), "true")
		var stderr strings.Builder
		cmd.Stderr = &stderr
		if err := cmd.Run(); err == nil {
			return nil
		} else {
			lastErr = fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
		}
		if time.Now().After(deadline) {
			return lastErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// Herdr registration.

type herdrMachine struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Target  string `json:"target"`
	Session string `json:"session"`
	Enabled bool   `json:"enabled"`
}

func herdrMachineAddArgs(id string) []string {
	return []string{"machine", "add", containerName(id), "--label", id, "--remote-session", herdrRemoteSession}
}

func herdrMachineRegistered(machines []herdrMachine, id string) bool {
	for _, m := range machines {
		if m.Target == containerName(id) {
			return true
		}
	}
	return false
}

// registerHerdrMachines saves the container in whichever Herdr clients the
// Mac has: the TUI (herdr), the desktop app (hc), or both. An empty path
// means that client is not installed. It never fails dev up: the container
// stays up and, when neither client is installed, the user gets both
// commands.
func registerHerdrMachines(ctx context.Context, cfg config, id, herdrBin, hcBin string, stdout, stderr io.Writer) {
	if herdrBin == "" && hcBin == "" {
		notice(stderr, "Herdr is not installed on this Mac; install the Herdr app or the herdr TUI from https://herdr.dev, then register the container:")
		notice(stderr, "  app: hc %s", strings.Join(hcMachineAddArgs(id), " "))
		notice(stderr, "  TUI: herdr %s", strings.Join(herdrMachineAddArgs(id), " "))
		return
	}
	if herdrBin != "" {
		ensureHerdrMachine(ctx, cfg, herdrBin, id, stdout, stderr)
	} else {
		status(cfg, stdout, "skip: herdr (TUI) is not installed on this Mac")
	}
	if hcBin != "" {
		ensureHCMachine(ctx, cfg, hcBin, id, stdout, stderr)
	} else {
		status(cfg, stdout, "skip: hc (Herdr app) is not installed on this Mac")
	}
}

// ensureHerdrMachine registers the container as a saved Herdr TUI machine.
func ensureHerdrMachine(ctx context.Context, cfg config, herdrBin, id string, stdout, stderr io.Writer) {
	addLine := "herdr " + strings.Join(herdrMachineAddArgs(id), " ")
	out, err := exec.CommandContext(ctx, herdrBin, "machine", "list", "--json").Output()
	if err == nil {
		var machines []herdrMachine
		if jsonErr := json.Unmarshal(out, &machines); jsonErr == nil && herdrMachineRegistered(machines, id) {
			status(cfg, stdout, "ok: Herdr machine %s is saved", id)
			return
		}
	}

	status(cfg, stdout, "register: Herdr machine %s", id)
	if localOut, remoteOut := versionOutputs(ctx, cfg, herdrBin, "herdr", id); !versionsMatch(localOut, remoteOut, "herdr") {
		notice(stderr, "if Herdr offers to install a server into ~/.local/bin, answer no: the image already ships herdr, bump HERDR_VERSION with scripts/update-herdr.sh in the env repo instead")
	}
	if err := runOnTerminal(ctx, herdrBin, herdrMachineAddArgs(id)...); err != nil {
		notice(stderr, "herdr machine add failed: %v", err)
		notice(stderr, "the container is up; register it with:")
		notice(stderr, "  %s", addLine)
	}
}

// versionOutputs returns `<name> --version` from the Mac binary and from
// the container, or "" for one that can't be read. It asks the container
// over the same SSH alias machine add uses, so it sees the binary the dev
// user's login PATH resolves (including one an earlier add installed under
// ~/.local/bin), not what docker exec's root shell finds. It also asks the
// container directly because the version a Mac client last saw in its
// machine list is stale right after a rebuild.
func versionOutputs(ctx context.Context, cfg config, localBin, name, id string) (localOut, remoteOut string) {
	if out, err := exec.CommandContext(ctx, localBin, "--version").Output(); err == nil {
		localOut = string(out)
	}
	if out, err := exec.CommandContext(ctx, "ssh",
		"-F", userSSHConfigPath(cfg),
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=3",
		containerName(id), name, "--version").Output(); err == nil {
		remoteOut = string(out)
	}
	return localOut, remoteOut
}

// versionsMatch reports whether both `<name> --version` outputs carry a
// release and it is the same one. Only then can machine add have nothing to
// install or copy, so the warning before it is skipped.
func versionsMatch(localOut, remoteOut, name string) bool {
	local := releaseFromVersion(localOut, name)
	return local != "" && local == releaseFromVersion(remoteOut, name)
}

// releaseFromVersion reads the release out of `<name> --version` output
// ("herdr 0.9.5"). Only the first line counts; later lines may carry build
// details. A first line without the "<name> " prefix is not a version, so
// it gives "".
func releaseFromVersion(output, name string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(output), "\n")
	release, ok := strings.CutPrefix(strings.TrimSpace(line), name+" ")
	if !ok {
		return ""
	}
	return strings.TrimSpace(release)
}

func terminalFile(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

// notice writes a line the user must act on. It ignores --quiet.
func notice(stderr io.Writer, format string, args ...any) {
	fmt.Fprintf(stderr, format+"\n", args...)
}

// removeHerdrVolumes removes the per-worktree Herdr volumes for this root.
func removeHerdrVolumes(ctx context.Context, cfg config, stdout io.Writer) error {
	out, err := dockerOutput(ctx, "volume", "ls", "-q",
		"--filter", "label="+labelManaged+"=true",
		"--filter", "label="+labelRole+"=herdr",
		"--filter", "label="+labelRoot+"="+cfg.Root,
	)
	if err != nil {
		return fmt.Errorf("list Herdr volumes: %w", err)
	}
	names := strings.Fields(out)
	if len(names) == 0 {
		return nil
	}
	status(cfg, stdout, "remove: %d Herdr volume(s)", len(names))
	args := append([]string{"volume", "rm"}, names...)
	if _, err := dockerOutput(ctx, args...); err != nil {
		return fmt.Errorf("remove Herdr volumes: %w", err)
	}
	return nil
}
