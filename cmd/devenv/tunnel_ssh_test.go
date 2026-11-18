package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tunnelSessionEnvironment(t *testing.T, dir, username string) (string, tunnelState) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash required for entrypoint fixture")
	}
	data, err := os.ReadFile("../../dev.Dockerfile")
	if err != nil {
		t.Fatal(err)
	}
	section := func(start, end string) string {
		t.Helper()
		_, rest, ok := strings.Cut(string(data), start)
		if !ok {
			t.Fatalf("entrypoint section missing: %s", start)
		}
		body, _, ok := strings.Cut(rest, end)
		if !ok {
			t.Fatalf("entrypoint section end missing: %s", end)
		}
		return start + body
	}
	script := section("workspace_env_names=(", "cat > /etc/ssh/sshd_config.d/devenv.conf") + section("herdr_env=(", "herdr_server_running()") + `printf '%s\n' "$session_env"; printf '%s\n' "${herdr_env[@]}"`
	profile := tunnelState{ID: testTunnelID, Domain: "example.dev"}
	shell := exec.Command("bash", "-eu", "-c", script)
	runtimeEnv := append(engineEnvironment(worktree{CommonDir: "/repo/.git"}, worktreeRecord{ID: "test-worktree"}), profile.environment()...)
	shell.Env = append([]string{"PATH=" + os.Getenv("PATH"), "home_dir=" + dir, "user_name=" + username, "sqlite_home=" + dir, "image_path=" + os.Getenv("PATH"), "GIT_CONFIG_GLOBAL=/devenv/gitconfig"}, runtimeEnv...)
	out, err := shell.CombinedOutput()
	if err != nil {
		t.Fatalf("entrypoint environment generation: %s %v", out, err)
	}
	session, server, ok := strings.Cut(string(out), "\n")
	if !ok {
		t.Fatal("missing generated environment")
	}
	for _, value := range runtimeEnv {
		if !strings.Contains(session, " "+value) {
			t.Fatalf("SSH configuration missing %s", value)
		}
		if !strings.Contains(server, value+"\n") {
			t.Fatalf("supervised server missing %s", value)
		}
	}
	return session, profile
}

func TestTunnelSessionEnvironment(t *testing.T) {
	tunnelSessionEnvironment(t, t.TempDir(), "dev")
}

// Opt in where an SSH daemon can run without changing host setup. The normal
// suite always checks environment construction; this verifies the real SSH hop.
func TestTunnelMetadataThroughSSHSession(t *testing.T) {
	if os.Getenv("DEVENV_TEST_SSH") != "1" {
		t.Skip("set DEVENV_TEST_SSH=1 to exercise an actual local SSH session")
	}
	for _, tool := range []string{"bash", "ssh", "ssh-keygen"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("%s required for SSH fixture", tool)
		}
	}
	sshd, err := exec.LookPath("sshd")
	if err != nil {
		sshd = "/usr/sbin/sshd"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	current, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	key := filepath.Join(dir, "key")
	if out, err := exec.CommandContext(ctx, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key).CombinedOutput(); err != nil {
		t.Fatalf("fixture key: %s %v", out, err)
	}
	session, profile := tunnelSessionEnvironment(t, dir, current.Username)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	config := fmt.Sprintf("ListenAddress 127.0.0.1\nPort %d\nHostKey %s\nAuthorizedKeysFile %s.pub\nPidFile %s\nStrictModes no\nUsePAM no\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\nPermitUserEnvironment no\nAllowUsers %s\nSetEnv %s\n", port, key, key, filepath.Join(dir, "sshd.pid"), current.Username, session)
	configPath := filepath.Join(dir, "sshd_config")
	if err = os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	daemon := exec.CommandContext(ctx, sshd, "-D", "-e", "-f", configPath)
	daemon.Stderr = &logs
	if err = daemon.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { daemon.Process.Kill(); daemon.Wait() }()
	for {
		conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(port)), 100*time.Millisecond)
		if err == nil {
			conn.Close()
			break
		}
		select {
		case <-ctx.Done():
			daemon.Process.Kill()
			daemon.Wait()
			t.Fatalf("sshd did not start: %s", logs.String())
		case <-time.After(25 * time.Millisecond):
		}
	}
	remote := `printf '%s\n' "$DEVENV_INSTANCE_ID" "$DEVENV_PUBLIC_URL" "$DEVENV_FILES_URL" "$DEVENV_INGRESS_NETWORK"`
	client := exec.CommandContext(ctx, "ssh", "-F", "/dev/null", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", key, "-p", fmt.Sprint(port), current.Username+"@127.0.0.1", remote)
	var stderr bytes.Buffer
	client.Stderr = &stderr
	received, err := client.Output()
	if err != nil {
		t.Fatalf("SSH session: %v %s", err, stderr.String())
	}
	var want []string
	for _, value := range profile.environment() {
		_, v, _ := strings.Cut(value, "=")
		want = append(want, v)
	}
	if string(received) != strings.Join(want, "\n")+"\n" {
		t.Fatalf("SSH metadata mismatch: %q", received)
	}
}
