package main

import (
	"os"
	"testing"
)

func TestForwardedTerminalEnvOmitsUnsetCodexKeyboardEnhancement(t *testing.T) {
	os.Unsetenv("CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT")

	env := forwardedTerminalEnv()
	if _, ok := envValue(env, "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"); ok {
		t.Fatal("did not expect CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT when unset")
	}
}

func TestForwardedTerminalEnvRespectsCodexKeyboardEnhancementOverride(t *testing.T) {
	t.Setenv("CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT", "0")

	env := forwardedTerminalEnv()
	got, ok := envValue(env, "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT")
	if !ok {
		t.Fatal("expected CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT to be forwarded")
	}
	if got != "0" {
		t.Fatalf("disable keyboard enhancement override = %q, want 0", got)
	}
}

func TestForwardedTerminalEnvPassesGhosttyIdentity(t *testing.T) {
	t.Setenv("TERM", "xterm-ghostty")
	t.Setenv("TERM_PROGRAM", "ghostty")
	t.Setenv("GHOSTTY_RESOURCES_DIR", "/Applications/Ghostty.app/Contents/Resources/ghostty")
	os.Unsetenv("CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT")

	env := forwardedTerminalEnv()
	cases := map[string]string{
		"TERM":                  "xterm-ghostty",
		"TERM_PROGRAM":          "ghostty",
		"GHOSTTY_RESOURCES_DIR": "/Applications/Ghostty.app/Contents/Resources/ghostty",
	}
	for name, want := range cases {
		got, ok := envValue(env, name)
		if !ok {
			t.Fatalf("missing forwarded env %s", name)
		}
		if got != want {
			t.Fatalf("%s = %q, want %q", name, got, want)
		}
	}
	if _, ok := envValue(env, "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"); ok {
		t.Fatal("did not expect CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT when unset")
	}
}

func TestDevDockerRunArgsMountsCodexSqliteVolume(t *testing.T) {
	args, err := devDockerRunArgs(config{
		Image:          "local-dev:latest",
		Root:           "/tmp/devenv-test",
		ProxyContainer: "devenv-dockerproxy",
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := envValue(args, "CODEX_SQLITE_HOME")
	if !ok {
		t.Fatal("docker run args missing CODEX_SQLITE_HOME")
	}
	if got != "/var/lib/codex-sqlite" {
		t.Fatalf("CODEX_SQLITE_HOME = %q, want /var/lib/codex-sqlite", got)
	}
	wantMount := "type=volume,source=devenv-dockerproxy-codex-sqlite,target=/var/lib/codex-sqlite"
	if !containsArgPair(args, "--mount", wantMount) {
		t.Fatalf("docker run args missing Codex SQLite volume mount %q", wantMount)
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

func envValue(args []string, name string) (string, bool) {
	prefix := name + "="
	for i, arg := range args {
		if arg != "-e" || i+1 >= len(args) {
			continue
		}
		value := args[i+1]
		if len(value) >= len(prefix) && value[:len(prefix)] == prefix {
			return value[len(prefix):], true
		}
	}
	return "", false
}
