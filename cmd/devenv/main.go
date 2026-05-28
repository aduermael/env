package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	defaultDevImage       = "local-dev:latest"
	defaultProxyImage     = "wollomatic/socket-proxy:1.12.1"
	defaultProxyContainer = "devenv-dockerproxy"
	defaultProxyPort      = "23750"

	labelManaged = "com.aduermael.env.devenv.managed"
	labelRole    = "com.aduermael.env.devenv.role"
	labelRoot    = "com.aduermael.env.devenv.root"

	zshrcStartMarker = "# >>> devenv >>>"
	zshrcEndMarker   = "# <<< devenv <<<"
)

type config struct {
	Image          string
	ProxyImage     string
	Root           string
	Source         string
	Zshrc          string
	HostSocket     string
	ProxyContainer string
	ProxyPort      string
	SkipBuild      bool
	SkipEnsure     bool
	NoZshrc        bool
	Quiet          bool
	DeleteData     bool
}

type bridgeConfig struct {
	SocketPath string
	TCPAddress string
	PIDFile    string
}

type containerInspect struct {
	Config struct {
		Labels map[string]string `json:"Labels"`
	} `json:"Config"`
	State struct {
		Running bool `json:"Running"`
		Health  *struct {
			Status string `json:"Status"`
		} `json:"Health"`
	} `json:"State"`
}

func main() {
	ctx := context.Background()
	if err := run(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	if len(args) > 0 && (args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
		printUsage(stdout)
		return nil
	}

	cmd := "setup"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd = args[0]
		args = args[1:]
	}

	switch cmd {
	case "setup":
		cfg, err := parseSetupFlags(args)
		if err != nil {
			if errors.Is(err, flag.ErrHelp) {
				printUsage(stdout)
				return nil
			}
			return err
		}
		return setup(ctx, cfg, stdout, stderr)
	case "run":
		cfg, command, err := parseRunFlags(args)
		if err != nil {
			if errors.Is(err, flag.ErrHelp) {
				printUsage(stdout)
				return nil
			}
			return err
		}
		return runContainer(ctx, cfg, command, stdout, stderr)
	case "proxy-bridge":
		bridge, err := parseProxyBridgeFlags(args)
		if err != nil {
			return err
		}
		return runProxyBridge(bridge)
	case "down":
		cfg, err := parseDownFlags(args)
		if err != nil {
			if errors.Is(err, flag.ErrHelp) {
				printUsage(stdout)
				return nil
			}
			return err
		}
		return down(ctx, cfg, stdout, stderr)
	default:
		printUsage(stderr)
		return fmt.Errorf("unknown command %q", cmd)
	}
}

func baseConfig() (config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return config{}, fmt.Errorf("find user home: %w", err)
	}

	root := envOrDefault("DEVENV_HOME", filepath.Join(home, ".devenv"))
	zshrc := envOrDefault("DEVENV_ZSHRC", filepath.Join(home, ".zshrc"))

	return config{
		Image:          envOrDefault("DEVENV_IMAGE", defaultDevImage),
		ProxyImage:     envOrDefault("DEVENV_PROXY_IMAGE", defaultProxyImage),
		Root:           root,
		Source:         os.Getenv("DEVENV_SOURCE"),
		Zshrc:          zshrc,
		HostSocket:     os.Getenv("DEVENV_HOST_DOCKER_SOCKET"),
		ProxyContainer: envOrDefault("DEVENV_PROXY_CONTAINER", defaultProxyContainer),
		ProxyPort:      envOrDefault("DEVENV_PROXY_PORT", defaultProxyPort),
	}, nil
}

func parseSetupFlags(args []string) (config, error) {
	cfg, err := baseConfig()
	if err != nil {
		return config{}, err
	}

	fs := flag.NewFlagSet("setup", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&cfg.Image, "image", cfg.Image, "dev image reference")
	fs.StringVar(&cfg.ProxyImage, "proxy-image", cfg.ProxyImage, "safe Docker socket proxy image reference")
	fs.StringVar(&cfg.Root, "root", cfg.Root, "devenv state directory")
	fs.StringVar(&cfg.Source, "source", cfg.Source, "directory containing dev.Dockerfile")
	fs.StringVar(&cfg.Zshrc, "zshrc", cfg.Zshrc, "zshrc file to update")
	fs.StringVar(&cfg.HostSocket, "host-socket", cfg.HostSocket, "host Docker socket to proxy")
	fs.StringVar(&cfg.ProxyContainer, "proxy-container", cfg.ProxyContainer, "safe Docker socket proxy container name")
	fs.StringVar(&cfg.ProxyPort, "proxy-port", cfg.ProxyPort, "localhost port for the safe Docker socket proxy")
	fs.BoolVar(&cfg.SkipBuild, "skip-build", false, "skip building the dev image")
	fs.BoolVar(&cfg.NoZshrc, "no-zshrc", false, "skip zshrc installation")
	fs.BoolVar(&cfg.Quiet, "quiet", false, "reduce status output")
	if err := fs.Parse(args); err != nil {
		return config{}, err
	}
	if fs.NArg() != 0 {
		return config{}, fmt.Errorf("setup does not accept positional arguments: %s", strings.Join(fs.Args(), " "))
	}
	return normalizeConfig(cfg)
}

func parseRunFlags(args []string) (config, []string, error) {
	cfg, err := baseConfig()
	if err != nil {
		return config{}, nil, err
	}

	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&cfg.Image, "image", cfg.Image, "dev image reference")
	fs.StringVar(&cfg.ProxyImage, "proxy-image", cfg.ProxyImage, "safe Docker socket proxy image reference")
	fs.StringVar(&cfg.Root, "root", cfg.Root, "devenv state directory")
	fs.StringVar(&cfg.HostSocket, "host-socket", cfg.HostSocket, "host Docker socket to proxy")
	fs.StringVar(&cfg.ProxyContainer, "proxy-container", cfg.ProxyContainer, "safe Docker socket proxy container name")
	fs.StringVar(&cfg.ProxyPort, "proxy-port", cfg.ProxyPort, "localhost port for the safe Docker socket proxy")
	fs.BoolVar(&cfg.SkipEnsure, "skip-ensure", false, "skip state and proxy checks before running")
	fs.BoolVar(&cfg.Quiet, "quiet", false, "reduce status output")
	if err := fs.Parse(args); err != nil {
		return config{}, nil, err
	}
	cfg, err = normalizeConfig(cfg)
	if err != nil {
		return config{}, nil, err
	}
	return cfg, fs.Args(), nil
}

func parseProxyBridgeFlags(args []string) (bridgeConfig, error) {
	var cfg bridgeConfig
	fs := flag.NewFlagSet("proxy-bridge", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&cfg.SocketPath, "socket", "", "Unix socket path to expose")
	fs.StringVar(&cfg.TCPAddress, "tcp", "", "TCP address of the filtering proxy")
	fs.StringVar(&cfg.PIDFile, "pid-file", "", "pid file to write")
	if err := fs.Parse(args); err != nil {
		return bridgeConfig{}, err
	}
	if fs.NArg() != 0 {
		return bridgeConfig{}, fmt.Errorf("proxy-bridge does not accept positional arguments: %s", strings.Join(fs.Args(), " "))
	}
	if cfg.SocketPath == "" {
		return bridgeConfig{}, errors.New("proxy-bridge requires --socket")
	}
	if cfg.TCPAddress == "" {
		return bridgeConfig{}, errors.New("proxy-bridge requires --tcp")
	}
	return cfg, nil
}

func parseDownFlags(args []string) (config, error) {
	cfg, err := baseConfig()
	if err != nil {
		return config{}, err
	}

	fs := flag.NewFlagSet("down", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&cfg.Root, "root", cfg.Root, "devenv state directory")
	fs.StringVar(&cfg.ProxyContainer, "proxy-container", cfg.ProxyContainer, "safe Docker socket proxy container name")
	fs.StringVar(&cfg.ProxyPort, "proxy-port", cfg.ProxyPort, "localhost port for the safe Docker socket proxy")
	fs.BoolVar(&cfg.DeleteData, "delete-data", false, "delete the devenv state directory after removing containers")
	fs.BoolVar(&cfg.Quiet, "quiet", false, "reduce status output")
	if err := fs.Parse(args); err != nil {
		return config{}, err
	}
	if fs.NArg() != 0 {
		return config{}, fmt.Errorf("down does not accept positional arguments: %s", strings.Join(fs.Args(), " "))
	}
	return normalizeConfig(cfg)
}

func normalizeConfig(cfg config) (config, error) {
	var err error
	cfg.Root, err = expandAndAbs(cfg.Root)
	if err != nil {
		return config{}, fmt.Errorf("resolve root: %w", err)
	}
	if cfg.Source != "" {
		cfg.Source, err = expandAndAbs(cfg.Source)
		if err != nil {
			return config{}, fmt.Errorf("resolve source: %w", err)
		}
	}
	cfg.Zshrc, err = expandAndAbs(cfg.Zshrc)
	if err != nil {
		return config{}, fmt.Errorf("resolve zshrc: %w", err)
	}
	if cfg.HostSocket != "" {
		cfg.HostSocket, err = expandAndAbs(strings.TrimPrefix(cfg.HostSocket, "unix://"))
		if err != nil {
			return config{}, fmt.Errorf("resolve host socket: %w", err)
		}
	}
	if cfg.Image == "" {
		return config{}, errors.New("image must not be empty")
	}
	if cfg.ProxyImage == "" {
		return config{}, errors.New("proxy image must not be empty")
	}
	if cfg.ProxyContainer == "" {
		return config{}, errors.New("proxy container name must not be empty")
	}
	if cfg.ProxyPort == "" {
		return config{}, errors.New("proxy port must not be empty")
	}
	port, err := strconv.Atoi(cfg.ProxyPort)
	if err != nil || port < 1 || port > 65535 {
		return config{}, fmt.Errorf("proxy port must be a TCP port number: %q", cfg.ProxyPort)
	}
	return cfg, nil
}

func setup(ctx context.Context, cfg config, stdout, stderr io.Writer) error {
	if err := ensureMacOS(); err != nil {
		return err
	}
	status(cfg, stdout, "check: Docker CLI and daemon")
	if err := dockerCheck(ctx); err != nil {
		return err
	}
	status(cfg, stdout, "ok: Docker is available")

	if err := ensureLayout(cfg, stdout); err != nil {
		return err
	}
	if err := ensureSelfInstalled(cfg, stdout); err != nil {
		return err
	}
	if err := ensureGitconfig(cfg, stdout); err != nil {
		return err
	}
	if err := ensureSSH(cfg, stdout, stderr); err != nil {
		return err
	}

	if !cfg.SkipBuild {
		source, err := discoverSourceDir(cfg.Source)
		if err != nil {
			return err
		}
		cfg.Source = source
		status(cfg, stdout, "build: %s from %s", cfg.Image, filepath.Join(source, "dev.Dockerfile"))
		if err := dockerRun(ctx, stdoutFor(cfg, stdout), stderrFor(cfg, stderr), "build", "-f", filepath.Join(source, "dev.Dockerfile"), "-t", cfg.Image, source); err != nil {
			return fmt.Errorf("build dev image %s: %w", cfg.Image, err)
		}
	} else {
		status(cfg, stdout, "skip: dev image build")
	}

	hostSocket, err := hostDockerSocket(cfg)
	if err != nil {
		return err
	}
	cfg.HostSocket = hostSocket
	status(cfg, stdout, "ok: host Docker socket %s", hostSocket)

	if err := ensureProxy(ctx, cfg, hostSocket, stdout, stderr); err != nil {
		return err
	}

	if !cfg.NoZshrc {
		if err := installZshrc(cfg, stdout); err != nil {
			return err
		}
		status(cfg, stdout, "")
		status(cfg, stdout, "✅ dev env is ready")
		status(cfg, stdout, "⚠️ existing terminals need: source %s", displayPath(cfg.Zshrc))
	} else {
		status(cfg, stdout, "skip: zshrc block")
		status(cfg, stdout, "")
		status(cfg, stdout, "✅ dev env is ready")
	}
	return nil
}

func runContainer(ctx context.Context, cfg config, command []string, stdout, stderr io.Writer) error {
	if err := ensureMacOS(); err != nil {
		return err
	}
	if !cfg.SkipEnsure {
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
		hostSocket, err := hostDockerSocket(cfg)
		if err != nil {
			return err
		}
		cfg.HostSocket = hostSocket
		if err := ensureProxy(ctx, cfg, hostSocket, stdout, stderr); err != nil {
			return err
		}
	} else if !isSocket(filepath.Join(cfg.Root, "run", "docker.sock")) {
		return fmt.Errorf("safe Docker socket is not ready; run devenv setup or omit --skip-ensure")
	}

	args, err := devDockerRunArgs(cfg, command)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

func down(ctx context.Context, cfg config, stdout, stderr io.Writer) error {
	status(cfg, stdout, "check: Docker CLI and daemon")
	if err := dockerCheck(ctx); err != nil {
		return err
	}

	out, err := dockerOutput(ctx, "ps", "-aq", "--filter", "label="+labelManaged+"=true", "--filter", "label="+labelRoot+"="+cfg.Root)
	if err != nil {
		return fmt.Errorf("list managed containers: %w", err)
	}
	ids := strings.Fields(out)
	if len(ids) == 0 {
		status(cfg, stdout, "ok: no managed containers to remove")
	} else {
		args := append([]string{"rm", "-f"}, ids...)
		status(cfg, stdout, "remove: %d managed container(s)", len(ids))
		if err := dockerRun(ctx, stdoutFor(cfg, stdout), stderrFor(cfg, stderr), args...); err != nil {
			return fmt.Errorf("remove managed containers: %w", err)
		}
	}

	if err := stopProxyBridge(cfg); err != nil {
		return err
	}
	if err := removeProxyNetwork(ctx, cfg); err != nil {
		return err
	}

	socketPath := filepath.Join(cfg.Root, "run", "docker.sock")
	if err := removeSocketIfPresent(socketPath); err != nil {
		return err
	}

	if cfg.DeleteData {
		status(cfg, stdout, "delete: %s", cfg.Root)
		if err := os.RemoveAll(cfg.Root); err != nil {
			return fmt.Errorf("delete devenv state directory: %w", err)
		}
	} else {
		status(cfg, stdout, "keep: %s", cfg.Root)
	}

	status(cfg, stdout, "done: devenv containers are down")
	return nil
}

func ensureLayout(cfg config, stdout io.Writer) error {
	dirs := []struct {
		path string
		mode os.FileMode
	}{
		{cfg.Root, 0o700},
		{filepath.Join(cfg.Root, "bin"), 0o755},
		{filepath.Join(cfg.Root, "home"), 0o755},
		{filepath.Join(cfg.Root, "home", ".codex"), 0o700},
		{filepath.Join(cfg.Root, "ssh"), 0o700},
		{filepath.Join(cfg.Root, "run"), 0o700},
	}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir.path, dir.mode); err != nil {
			return fmt.Errorf("create %s: %w", dir.path, err)
		}
		if err := os.Chmod(dir.path, dir.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", dir.path, err)
		}
	}
	status(cfg, stdout, "ok: state directory %s", cfg.Root)
	return nil
}

func ensureMacOS() error {
	if runtime.GOOS != "darwin" {
		return fmt.Errorf("devenv setup currently supports macOS only; current platform is %s", runtime.GOOS)
	}
	return nil
}

func discoverSourceDir(configured string) (string, error) {
	if configured != "" {
		if fileExists(filepath.Join(configured, "dev.Dockerfile")) {
			return configured, nil
		}
		return "", fmt.Errorf("dev.Dockerfile not found in --source %s", configured)
	}

	var candidates []string
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates, parentCandidates(cwd, 4)...)
	}
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			candidates = append(candidates, parentCandidates(filepath.Dir(resolved), 4)...)
		}
	}

	seen := map[string]bool{}
	for _, candidate := range candidates {
		if candidate == "" || seen[candidate] {
			continue
		}
		seen[candidate] = true
		if fileExists(filepath.Join(candidate, "dev.Dockerfile")) {
			return candidate, nil
		}
	}

	return "", errors.New("dev.Dockerfile not found; run setup from this repo or pass --source /path/to/env")
}

func parentCandidates(start string, maxDepth int) []string {
	var out []string
	current := start
	for i := 0; i <= maxDepth; i++ {
		out = append(out, current)
		next := filepath.Dir(current)
		if next == current {
			break
		}
		current = next
	}
	return out
}

func ensureSelfInstalled(cfg config, stdout io.Writer) error {
	source, err := os.Executable()
	if err != nil {
		return fmt.Errorf("find devenv executable: %w", err)
	}
	source, err = filepath.EvalSymlinks(source)
	if err != nil {
		return fmt.Errorf("resolve devenv executable: %w", err)
	}

	target := filepath.Join(cfg.Root, "bin", "devenv")
	if sameFile(source, target) {
		status(cfg, stdout, "ok: devenv binary is installed")
		return nil
	}

	if err := copyFile(source, target, 0o755); err != nil {
		return fmt.Errorf("install devenv binary: %w", err)
	}
	status(cfg, stdout, "install: %s", target)
	return nil
}

func sameFile(left, right string) bool {
	leftInfo, leftErr := os.Stat(left)
	rightInfo, rightErr := os.Stat(right)
	return leftErr == nil && rightErr == nil && os.SameFile(leftInfo, rightInfo)
}

func copyFile(source, target string, mode os.FileMode) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	tmp := target + ".tmp"
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(tmp)
		return copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmp)
		return closeErr
	}
	if err := os.Chmod(tmp, mode); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, target)
}

func ensureGitconfig(cfg config, stdout io.Writer) error {
	path := filepath.Join(cfg.Root, "gitconfig")
	if _, err := os.Stat(path); err == nil {
		status(cfg, stdout, "ok: gitconfig exists")
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("stat gitconfig: %w", err)
	}

	content := strings.Join([]string{
		"# Managed by devenv. Customize this file for container-only Git settings.",
		"[worktree]",
		"\tuseRelativePaths = true",
		"",
	}, "\n")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return fmt.Errorf("write gitconfig: %w", err)
	}
	status(cfg, stdout, "create: gitconfig")
	return nil
}

func ensureSSH(cfg config, stdout, stderr io.Writer) error {
	sshDir := filepath.Join(cfg.Root, "ssh")
	if err := os.Chmod(sshDir, 0o700); err != nil {
		return fmt.Errorf("chmod ssh directory: %w", err)
	}

	privateKey := filepath.Join(sshDir, "id_ed25519")
	publicKey := privateKey + ".pub"
	privateExists := fileExists(privateKey)
	publicExists := fileExists(publicKey)

	if privateExists {
		if err := os.Chmod(privateKey, 0o600); err != nil {
			return fmt.Errorf("chmod ssh private key: %w", err)
		}
	}
	if publicExists {
		if err := os.Chmod(publicKey, 0o644); err != nil {
			return fmt.Errorf("chmod ssh public key: %w", err)
		}
	}

	switch {
	case privateExists && publicExists:
		status(cfg, stdout, "ok: ssh keypair exists")
	case privateExists || publicExists:
		status(cfg, stdout, "warn: incomplete ssh keypair in %s; leaving it unchanged", sshDir)
	default:
		if err := generateSSHKeypair(privateKey, stdoutFor(cfg, stdout), stderrFor(cfg, stderr)); err != nil {
			status(cfg, stdout, "skip: ssh keypair generation failed: %v", err)
			return nil
		}
		if err := os.Chmod(privateKey, 0o600); err != nil {
			return fmt.Errorf("chmod generated ssh private key: %w", err)
		}
		if err := os.Chmod(publicKey, 0o644); err != nil {
			return fmt.Errorf("chmod generated ssh public key: %w", err)
		}
		status(cfg, stdout, "create: ssh keypair")
	}

	return nil
}

func generateSSHKeypair(privateKey string, stdout, stderr io.Writer) error {
	sshKeygen, err := exec.LookPath("ssh-keygen")
	if err != nil {
		return errors.New("ssh-keygen not found")
	}
	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "host"
	}
	comment := "devenv@" + hostname
	cmd := exec.Command(sshKeygen, "-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", privateKey)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

func hostDockerSocket(cfg config) (string, error) {
	candidates := []string{}
	if cfg.HostSocket != "" {
		candidates = append(candidates, cfg.HostSocket)
	}
	if dockerHost := os.Getenv("DOCKER_HOST"); strings.HasPrefix(dockerHost, "unix://") {
		candidates = append(candidates, strings.TrimPrefix(dockerHost, "unix://"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".docker", "run", "docker.sock"))
	}
	candidates = append(candidates, "/var/run/docker.sock")

	seen := map[string]bool{}
	for _, candidate := range candidates {
		if candidate == "" || seen[candidate] {
			continue
		}
		seen[candidate] = true
		if isSocket(candidate) {
			return candidate, nil
		}
	}

	return "", errors.New("Docker socket not found; set DEVENV_HOST_DOCKER_SOCKET or pass --host-socket")
}

func ensureProxy(ctx context.Context, cfg config, hostSocket string, stdout, stderr io.Writer) error {
	runDir := filepath.Join(cfg.Root, "run")
	socketPath := filepath.Join(runDir, "docker.sock")
	tcpAddress := net.JoinHostPort("127.0.0.1", cfg.ProxyPort)

	info, exists, err := inspectContainer(ctx, cfg.ProxyContainer)
	if err != nil {
		return fmt.Errorf("inspect proxy container: %w", err)
	}

	if exists {
		if info.Config.Labels[labelManaged] != "true" || info.Config.Labels[labelRole] != "proxy" {
			return fmt.Errorf("container %q already exists and is not managed by devenv", cfg.ProxyContainer)
		}
		if info.State.Running {
			if err := waitForProxyTCP(ctx, tcpAddress, cfg.ProxyContainer, 3*time.Second); err == nil {
				status(cfg, stdout, "ok: Docker socket proxy container is running")
				if err := ensureProxyBridge(ctx, cfg, socketPath, tcpAddress, stdout, stderr); err != nil {
					return err
				}
				if err := waitForProxy(ctx, socketPath, cfg.ProxyContainer, 10*time.Second); err != nil {
					return fmt.Errorf("wait for Docker socket bridge: %w", err)
				}
				status(cfg, stdout, "ok: Docker socket proxy is healthy")
				return nil
			}
			status(cfg, stdout, "recreate: Docker socket proxy is not healthy")
		} else {
			status(cfg, stdout, "recreate: Docker socket proxy is stopped")
		}
		if err := dockerRun(ctx, stdoutFor(cfg, stdout), stderrFor(cfg, stderr), "rm", "-f", cfg.ProxyContainer); err != nil {
			return fmt.Errorf("remove existing proxy container: %w", err)
		}
		if err := removeSocketIfPresent(socketPath); err != nil {
			return err
		}
		if err := stopProxyBridge(cfg); err != nil {
			return err
		}
	}

	if err := removeSocketIfPresent(socketPath); err != nil {
		return err
	}
	if err := stopProxyBridge(cfg); err != nil {
		return err
	}
	if err := ensureProxyNetwork(ctx, cfg, stdout, stderr); err != nil {
		return err
	}

	status(cfg, stdout, "start: Docker socket proxy")
	args := []string{
		"run", "-d",
		"--name", cfg.ProxyContainer,
		"--restart", "unless-stopped",
		"--user", "0:0",
		"--label", labelManaged + "=true",
		"--label", labelRole + "=proxy",
		"--label", labelRoot + "=" + cfg.Root,
		"--network", proxyNetworkName(cfg),
		"-p", net.JoinHostPort("127.0.0.1", cfg.ProxyPort) + ":2375",
		"--mount", "type=bind,source=" + hostSocket + ",target=/var/run/docker-host.sock,readonly",
		"-e", "SP_LOGLEVEL=INFO",
		"-e", "SP_SOCKETPATH=/var/run/docker-host.sock",
		"-e", "SP_LISTENIP=0.0.0.0",
		"-e", "SP_ALLOWFROM=0.0.0.0/0",
		"-e", "SP_ALLOWBINDMOUNTFROM=/.no-bind-mounts-allowed",
		"-e", "SP_ALLOW_HEAD=.*",
		"-e", "SP_ALLOW_GET=.*",
		"-e", "SP_ALLOW_POST=.*",
		"-e", "SP_ALLOW_PUT=.*",
		"-e", "SP_ALLOW_DELETE=.*",
		cfg.ProxyImage,
	}
	if err := dockerRun(ctx, stdoutFor(cfg, stdout), stderrFor(cfg, stderr), args...); err != nil {
		return fmt.Errorf("start Docker socket proxy: %w", err)
	}
	if err := waitForProxyTCP(ctx, tcpAddress, cfg.ProxyContainer, 20*time.Second); err != nil {
		return fmt.Errorf("wait for Docker socket proxy container: %w", err)
	}
	if err := ensureProxyBridge(ctx, cfg, socketPath, tcpAddress, stdout, stderr); err != nil {
		return err
	}
	if err := waitForProxy(ctx, socketPath, cfg.ProxyContainer, 20*time.Second); err != nil {
		return fmt.Errorf("wait for Docker socket bridge: %w", err)
	}
	status(cfg, stdout, "ok: Docker socket proxy is healthy")
	return nil
}

func ensureProxyNetwork(ctx context.Context, cfg config, stdout, stderr io.Writer) error {
	name := proxyNetworkName(cfg)
	if _, err := dockerOutput(ctx, "network", "inspect", name); err == nil {
		return nil
	} else if !isDockerNotFound(err) {
		return fmt.Errorf("inspect proxy network: %w", err)
	}

	status(cfg, stdout, "create: Docker proxy network")
	if err := dockerRun(ctx, stdoutFor(cfg, stdout), stderrFor(cfg, stderr),
		"network", "create",
		"--label", labelManaged+"=true",
		"--label", labelRole+"=network",
		"--label", labelRoot+"="+cfg.Root,
		name,
	); err != nil {
		return fmt.Errorf("create proxy network: %w", err)
	}
	return nil
}

func removeProxyNetwork(ctx context.Context, cfg config) error {
	if _, err := dockerOutput(ctx, "network", "rm", proxyNetworkName(cfg)); err != nil {
		if isDockerNotFound(err) {
			return nil
		}
		return fmt.Errorf("remove proxy network: %w", err)
	}
	return nil
}

func proxyNetworkName(cfg config) string {
	return cfg.ProxyContainer + "-net"
}

func waitForProxy(ctx context.Context, socketPath, containerName string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		if time.Now().After(deadline) {
			if lastErr != nil {
				return lastErr
			}
			return fmt.Errorf("timed out waiting for %s", socketPath)
		}

		info, exists, err := inspectContainer(ctx, containerName)
		if err != nil {
			lastErr = err
		} else if !exists {
			lastErr = fmt.Errorf("container %s does not exist", containerName)
		} else if !info.State.Running {
			lastErr = fmt.Errorf("container %s is not running", containerName)
		} else if info.State.Health != nil && info.State.Health.Status == "unhealthy" {
			lastErr = fmt.Errorf("container %s is unhealthy", containerName)
		} else if !isSocket(socketPath) {
			lastErr = fmt.Errorf("socket %s is not ready", socketPath)
		} else if err := proxyVersion(ctx, socketPath); err != nil {
			lastErr = err
		} else {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func waitForProxyTCP(ctx context.Context, tcpAddress, containerName string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		if time.Now().After(deadline) {
			if lastErr != nil {
				return lastErr
			}
			return fmt.Errorf("timed out waiting for proxy TCP address %s", tcpAddress)
		}

		info, exists, err := inspectContainer(ctx, containerName)
		if err != nil {
			lastErr = err
		} else if !exists {
			lastErr = fmt.Errorf("container %s does not exist", containerName)
		} else if !info.State.Running {
			lastErr = fmt.Errorf("container %s is not running", containerName)
		} else if info.State.Health != nil && info.State.Health.Status == "unhealthy" {
			lastErr = fmt.Errorf("container %s is unhealthy", containerName)
		} else if err := proxyTCPVersion(ctx, tcpAddress); err != nil {
			lastErr = err
		} else {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func proxyVersion(ctx context.Context, socketPath string) error {
	_, err := dockerOutput(ctx, "--host", "unix://"+socketPath, "version", "--format", "{{.Server.Version}}")
	if err != nil {
		return fmt.Errorf("proxy Docker API check failed: %w", err)
	}
	return nil
}

func proxyTCPVersion(ctx context.Context, tcpAddress string) error {
	_, err := dockerOutput(ctx, "--host", "tcp://"+tcpAddress, "version", "--format", "{{.Server.Version}}")
	if err != nil {
		return fmt.Errorf("proxy Docker API TCP check failed: %w", err)
	}
	return nil
}

func ensureProxyBridge(ctx context.Context, cfg config, socketPath, tcpAddress string, stdout, stderr io.Writer) error {
	if isSocket(socketPath) {
		if err := proxyVersion(ctx, socketPath); err == nil {
			status(cfg, stdout, "ok: Docker socket bridge is running")
			return nil
		}
	}

	if err := stopProxyBridge(cfg); err != nil {
		return err
	}
	if err := removeSocketIfPresent(socketPath); err != nil {
		return err
	}

	binary := filepath.Join(cfg.Root, "bin", "devenv")
	if !fileExists(binary) {
		exe, err := os.Executable()
		if err != nil {
			return fmt.Errorf("find devenv executable for proxy bridge: %w", err)
		}
		binary = exe
	}

	logPath := filepath.Join(cfg.Root, "run", "proxy-bridge.log")
	logFile, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("open proxy bridge log: %w", err)
	}
	defer logFile.Close()

	status(cfg, stdout, "start: Docker socket bridge")
	cmd := exec.CommandContext(ctx, binary,
		"proxy-bridge",
		"--socket", socketPath,
		"--tcp", tcpAddress,
		"--pid-file", proxyBridgePIDFile(cfg),
	)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	detachCommand(cmd)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start Docker socket bridge: %w", err)
	}
	return nil
}

func stopProxyBridge(cfg config) error {
	pidPath := proxyBridgePIDFile(cfg)
	data, err := os.ReadFile(pidPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read proxy bridge pid file: %w", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		_ = os.Remove(pidPath)
		return nil
	}
	process, err := os.FindProcess(pid)
	if err == nil {
		_ = process.Signal(os.Interrupt)
		time.Sleep(200 * time.Millisecond)
		_ = process.Kill()
	}
	_ = os.Remove(pidPath)
	return nil
}

func proxyBridgePIDFile(cfg config) string {
	return filepath.Join(cfg.Root, "run", "proxy-bridge.pid")
}

func runProxyBridge(cfg bridgeConfig) error {
	if err := os.MkdirAll(filepath.Dir(cfg.SocketPath), 0o700); err != nil {
		return fmt.Errorf("create proxy bridge socket directory: %w", err)
	}
	if err := removeSocketIfPresent(cfg.SocketPath); err != nil {
		return err
	}

	listener, err := net.Listen("unix", cfg.SocketPath)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.SocketPath, err)
	}
	defer listener.Close()
	defer os.Remove(cfg.SocketPath)

	if err := os.Chmod(cfg.SocketPath, 0o600); err != nil {
		return fmt.Errorf("chmod proxy bridge socket: %w", err)
	}
	if cfg.PIDFile != "" {
		if err := os.WriteFile(cfg.PIDFile, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o600); err != nil {
			return fmt.Errorf("write proxy bridge pid file: %w", err)
		}
		defer os.Remove(cfg.PIDFile)
	}

	for {
		conn, err := listener.Accept()
		if err != nil {
			return fmt.Errorf("accept proxy bridge connection: %w", err)
		}
		go bridgeConnection(conn, cfg.TCPAddress)
	}
}

func bridgeConnection(client net.Conn, tcpAddress string) {
	defer client.Close()
	upstream, err := net.Dial("tcp", tcpAddress)
	if err != nil {
		return
	}
	defer upstream.Close()

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(upstream, client)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, upstream)
		done <- struct{}{}
	}()
	<-done
}

func devDockerRunArgs(cfg config, command []string) ([]string, error) {
	workspace, err := os.Getwd()
	if err != nil {
		return nil, fmt.Errorf("find current directory: %w", err)
	}

	args := []string{
		"run",
		"--rm",
		"--label", labelManaged + "=true",
		"--label", labelRole + "=dev",
		"--label", labelRoot + "=" + cfg.Root,
		"--network", proxyNetworkName(cfg),
		"-e", "LOCAL_USER_ID=" + fmt.Sprint(os.Getuid()),
		"-e", "LOCAL_GROUP_ID=" + fmt.Sprint(os.Getgid()),
		"-e", "DOCKER_HOST=tcp://" + cfg.ProxyContainer + ":2375",
		"-e", "GIT_CONFIG_GLOBAL=/devenv/gitconfig",
		"-v", workspace + ":/workspace",
		"--mount", "type=bind,source=" + cfg.Root + ",target=/devenv,readonly",
		"--mount", "type=bind,source=" + filepath.Join(cfg.Root, "home") + ",target=/home/dev",
		"--mount", "type=bind,source=" + filepath.Join(cfg.Root, "ssh") + ",target=/home/dev/.ssh",
	}

	if terminalFile(os.Stdin) && terminalFile(os.Stdout) {
		args = append(args, "-it")
	}

	for _, name := range []string{
		"TERM",
		"COLORTERM",
		"TERM_PROGRAM",
		"TERM_PROGRAM_VERSION",
		"KITTY_WINDOW_ID",
		"WEZTERM_PANE",
		"GHOSTTY_RESOURCES_DIR",
		"VTE_VERSION",
		"CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT",
	} {
		if value := os.Getenv(name); value != "" {
			args = append(args, "-e", name+"="+value)
		}
	}

	args = append(args, cfg.Image)
	args = append(args, command...)
	return args, nil
}

func terminalFile(file *os.File) bool {
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func installZshrc(cfg config, stdout io.Writer) error {
	block := zshrcBlock(cfg)
	data, err := os.ReadFile(cfg.Zshrc)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read zshrc: %w", err)
	}

	text := string(data)
	next, changed, err := replaceManagedBlock(text, block)
	if err != nil {
		return err
	}
	if !changed {
		status(cfg, stdout, "ok: zshrc block is current")
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(cfg.Zshrc), 0o755); err != nil {
		return fmt.Errorf("create zshrc directory: %w", err)
	}
	if err := os.WriteFile(cfg.Zshrc, []byte(next), 0o644); err != nil {
		return fmt.Errorf("write zshrc: %w", err)
	}
	status(cfg, stdout, "update: zshrc block in %s", cfg.Zshrc)
	return nil
}

func replaceManagedBlock(text, block string) (string, bool, error) {
	start := strings.Index(text, zshrcStartMarker)
	end := strings.Index(text, zshrcEndMarker)
	if (start == -1) != (end == -1) {
		return "", false, errors.New("found incomplete devenv managed block in zshrc")
	}

	block = strings.TrimRight(block, "\n") + "\n"
	if start >= 0 {
		end += len(zshrcEndMarker)
		for end < len(text) && (text[end] == '\n' || text[end] == '\r') {
			end++
		}
		next := text[:start] + block + text[end:]
		return next, next != text, nil
	}

	var b strings.Builder
	b.WriteString(text)
	if text != "" && !strings.HasSuffix(text, "\n") {
		b.WriteByte('\n')
	}
	if text != "" {
		b.WriteByte('\n')
	}
	b.WriteString(block)
	return b.String(), true, nil
}

func zshrcBlock(cfg config) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", zshrcStartMarker)
	b.WriteString("# Managed by devenv. Changes inside this block will be replaced.\n")
	fmt.Fprintf(&b, "export DEVENV_HOME=\"${DEVENV_HOME:-%s}\"\n", shellDoubleQuoteContent(cfg.Root))
	b.WriteString(`case ":$PATH:" in
  *":$DEVENV_HOME/bin:"*) ;;
  *) export PATH="$DEVENV_HOME/bin:$PATH" ;;
esac
`)
	fmt.Fprintf(&b, "export DEVENV_IMAGE=\"${DEVENV_IMAGE:-%s}\"\n", shellDoubleQuoteContent(cfg.Image))
	if cfg.Source != "" {
		fmt.Fprintf(&b, "export DEVENV_SOURCE=\"${DEVENV_SOURCE:-%s}\"\n", shellDoubleQuoteContent(cfg.Source))
	}
	fmt.Fprintf(&b, "export DEVENV_PROXY_IMAGE=\"${DEVENV_PROXY_IMAGE:-%s}\"\n", shellDoubleQuoteContent(cfg.ProxyImage))
	fmt.Fprintf(&b, "export DEVENV_PROXY_CONTAINER=\"${DEVENV_PROXY_CONTAINER:-%s}\"\n", shellDoubleQuoteContent(cfg.ProxyContainer))
	fmt.Fprintf(&b, "export DEVENV_PROXY_PORT=\"${DEVENV_PROXY_PORT:-%s}\"\n", shellDoubleQuoteContent(cfg.ProxyPort))
	if cfg.HostSocket != "" {
		fmt.Fprintf(&b, "export DEVENV_HOST_DOCKER_SOCKET=\"${DEVENV_HOST_DOCKER_SOCKET:-%s}\"\n", shellDoubleQuoteContent(cfg.HostSocket))
	}
	b.WriteString(`
dev() {
  command devenv run --quiet -- "$@"
}

codex() {
  command devenv run --quiet -- codex "$@"
}

claude() {
  command devenv run --quiet -- claude "$@"
}

gemini() {
  command devenv run --quiet -- gemini "$@"
}
`)
	fmt.Fprintf(&b, "%s\n", zshrcEndMarker)
	return b.String()
}

func dockerCheck(ctx context.Context) error {
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("docker CLI not found in PATH")
	}
	if _, err := dockerOutput(ctx, "version"); err != nil {
		return fmt.Errorf("Docker daemon is not available: %w", err)
	}
	return nil
}

func inspectContainer(ctx context.Context, name string) (containerInspect, bool, error) {
	out, err := dockerOutput(ctx, "inspect", name)
	if err != nil {
		if isDockerNotFound(err) {
			return containerInspect{}, false, nil
		}
		return containerInspect{}, false, err
	}
	var containers []containerInspect
	if err := json.Unmarshal([]byte(out), &containers); err != nil {
		return containerInspect{}, false, fmt.Errorf("parse docker inspect: %w", err)
	}
	if len(containers) == 0 {
		return containerInspect{}, false, nil
	}
	return containers[0], true, nil
}

func dockerRun(ctx context.Context, stdout, stderr io.Writer, args ...string) error {
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	return cmd.Run()
}

func dockerOutput(ctx context.Context, args ...string) (string, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg != "" {
			return "", fmt.Errorf("%w: %s", err, msg)
		}
		return "", err
	}
	return stdout.String(), nil
}

func isDockerNotFound(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "no such object") ||
		strings.Contains(msg, "no such container") ||
		strings.Contains(msg, "not found")
}

func removeSocketIfPresent(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("stat socket %s: %w", path, err)
	}
	if info.Mode()&os.ModeSocket == 0 && info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("refusing to remove non-socket %s", path)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale socket %s: %w", path, err)
	}
	return nil
}

func isSocket(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode()&os.ModeSocket != 0
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func expandAndAbs(path string) (string, error) {
	if path == "" {
		return "", errors.New("path is empty")
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		if path == "~" {
			path = home
		} else {
			path = filepath.Join(home, path[2:])
		}
	}
	return filepath.Abs(path)
}

func shellDoubleQuoteContent(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`, `$`, `\$`, "`", "\\`")
	return replacer.Replace(value)
}

func displayPath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if path == home {
		return "~"
	}
	if strings.HasPrefix(path, home+string(os.PathSeparator)) {
		return "~/" + strings.TrimPrefix(path, home+string(os.PathSeparator))
	}
	return path
}

func status(cfg config, stdout io.Writer, format string, args ...any) {
	if cfg.Quiet {
		return
	}
	fmt.Fprintf(stdout, format+"\n", args...)
}

func stdoutFor(cfg config, stdout io.Writer) io.Writer {
	if cfg.Quiet {
		return io.Discard
	}
	return stdout
}

func stderrFor(cfg config, stderr io.Writer) io.Writer {
	if cfg.Quiet {
		return io.Discard
	}
	return stderr
}

func printUsage(w io.Writer) {
	exe := "devenv"
	if len(os.Args) > 0 {
		exe = filepath.Base(os.Args[0])
	}
	fmt.Fprintf(w, `Usage:
  %[1]s [setup] [flags]
  %[1]s run [flags] [--] [command [args...]]
  %[1]s down [flags]

Commands:
  setup    Prepare ~/.devenv, build the dev image, start the socket proxy, and install zsh functions.
  run      Run a shell or command inside the dev container.
  down     Remove containers created by devenv. State in ~/.devenv is kept unless --delete-data is set.

Setup flags:
  --image string             Local dev image tag (default %q or DEVENV_IMAGE).
  --proxy-image string       Socket proxy image reference (default %q).
  --root path                State directory (default $HOME/.devenv or DEVENV_HOME).
  --source path              Directory containing dev.Dockerfile (default current repo or DEVENV_SOURCE).
  --zshrc path               zshrc file to update (default $HOME/.zshrc or DEVENV_ZSHRC).
  --host-socket path         Host Docker socket to proxy (or DEVENV_HOST_DOCKER_SOCKET).
  --proxy-container name     Proxy container name (default %q).
  --proxy-port port          Localhost port for the proxy container (default %q).
  --skip-build               Skip building the dev image.
  --no-zshrc                 Skip zshrc installation.

Run flags:
  --image string             Local dev image tag (default %q or DEVENV_IMAGE).
  --root path                State directory (default $HOME/.devenv or DEVENV_HOME).
  --host-socket path         Host Docker socket to proxy (or DEVENV_HOST_DOCKER_SOCKET).
  --proxy-container name     Proxy container name (default %q).
  --proxy-port port          Localhost port for the proxy container (default %q).
  --skip-ensure              Skip state and proxy checks before running.

Down flags:
  --root path                State directory (default $HOME/.devenv or DEVENV_HOME).
  --delete-data              Delete the state directory after removing containers.
`, exe, defaultDevImage, defaultProxyImage, defaultProxyContainer, defaultProxyPort, defaultDevImage, defaultProxyContainer, defaultProxyPort)

	if runtime.GOOS == "windows" {
		fmt.Fprintln(w, "\nNote: devenv expects a Unix-style Docker socket and zsh environment.")
	}
}
