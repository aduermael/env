package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Output shape recorded from hc 0.1.17 `machine ls --json`.
const hcMachineListFixture = `{"machines":[
 {"host":"ea98f17a3a44","id":"2bc4eb2fa3afa897626703fe5d17dd1c","name":"renamed","session":null,"state":"connected","target":"devenv-env-root-a1b2c3","temporary":false,"version":"0.1.17","via":false},
 {"host":"e7999ce4307b","id":"ecb578fc7b3513628e4564a4bf50d3ca","name":"env-feature-c4d5e6","session":null,"since_ms":1793772157813,"state":"unreachable","target":"devenv-env-feature-c4d5e6","temporary":false,"version":"0.1.17","via":false,"why":"a different core answers there (\"9bd80486ddccc256df3476be353a67f9\")"},
 {"host":"x","id":"3","name":"env-other-111111","session":null,"state":"unreachable","target":"devenv-env-other-111111","temporary":false,"version":"0.1.17","via":false,"why":"cannot reach devenv-env-other-111111: connection refused"},
 {"host":"y","id":"4","name":"env-root-a1b2c3","session":null,"state":"connected","target":"other-host","temporary":false,"version":"0.1.17","via":false}
]}`

func TestHCMachineActionMatchesTargetNotName(t *testing.T) {
	list, err := parseHCMachineList([]byte(hcMachineListFixture))
	if err != nil {
		t.Fatal(err)
	}
	action, m := hcMachineAction(list, "env-root-a1b2c3")
	if action != hcRegistered {
		t.Fatalf("action = %v, want registered", action)
	}
	if m.Name != "renamed" {
		t.Fatalf("matched %q, want the entry whose target is the alias", m.Name)
	}
	if action, _ := hcMachineAction(list, "env-missing-000000"); action != hcAdd {
		t.Fatalf("action for an unknown alias = %v, want add", action)
	}
}

func TestHCMachineActionReplacesOnlyDifferentCore(t *testing.T) {
	list, err := parseHCMachineList([]byte(hcMachineListFixture))
	if err != nil {
		t.Fatal(err)
	}
	action, m := hcMachineAction(list, "env-feature-c4d5e6")
	if action != hcReplace || m.Name != "env-feature-c4d5e6" {
		t.Fatalf("action = %v (%q), want replace", action, m.Name)
	}
	if action, _ := hcMachineAction(list, "env-other-111111"); action != hcRegistered {
		t.Fatalf("an unreachable machine with another reason must be left alone, got %v", action)
	}
}

func TestHCMachineAddArgsHasNoInstall(t *testing.T) {
	got := strings.Join(hcMachineAddArgs("env-root-a1b2c3"), " ")
	if got != "machine add devenv-env-root-a1b2c3 --name env-root-a1b2c3" {
		t.Fatalf("args = %q", got)
	}
}

func TestLookupHCPrefersPathThenLocalBin(t *testing.T) {
	home := t.TempDir()
	onPath := func(string) (string, error) { return "/opt/homebrew/bin/hc", nil }
	notOnPath := func(string) (string, error) { return "", errors.New("not found") }

	if path, ok := lookupHC(onPath, home); !ok || path != "/opt/homebrew/bin/hc" {
		t.Fatalf("PATH lookup = %q, %v", path, ok)
	}
	if _, ok := lookupHC(notOnPath, home); ok {
		t.Fatal("expected no hc without PATH or ~/.local/bin")
	}
	local := filepath.Join(home, ".local", "bin", "hc")
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(local, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if path, ok := lookupHC(notOnPath, home); !ok || path != local {
		t.Fatalf("~/.local/bin lookup = %q, %v", path, ok)
	}
}

func TestHCVersionMismatch(t *testing.T) {
	if _, _, mismatch := hcVersionMismatch("hc 0.1.17\n", "hc 0.1.17\n"); mismatch {
		t.Fatal("same versions must not mismatch")
	}
	local, remote, mismatch := hcVersionMismatch("hc 0.1.18\ncommit abc123\n", "hc 0.1.17\n")
	if !mismatch || local != "0.1.18" || remote != "0.1.17" {
		t.Fatalf("got %q %q %v", local, remote, mismatch)
	}
	if _, _, mismatch := hcVersionMismatch("hc 0.1.18\n", ""); mismatch {
		t.Fatal("an unknown remote version must not warn")
	}
}

func TestHCPreAddNotices(t *testing.T) {
	if lines := hcPreAddNotices("hc 0.1.18\n", "hc 0.1.18\n"); len(lines) != 0 {
		t.Fatalf("matching versions must not warn, got %q", lines)
	}
	lines := hcPreAddNotices("hc 0.1.18\n", "hc 0.1.17\n")
	if len(lines) != 2 || !strings.Contains(lines[0], "0.1.18") || !strings.Contains(lines[0], "update-herdr-core.sh") || !strings.Contains(lines[1], "answer no") {
		t.Fatalf("mismatch must give the version notice then the copy warning, got %q", lines)
	}
	for _, c := range [][2]string{{"hc 0.1.18\n", ""}, {"", "hc 0.1.18\n"}, {"", ""}} {
		lines := hcPreAddNotices(c[0], c[1])
		if len(lines) != 1 || !strings.Contains(lines[0], "answer no") || !strings.Contains(lines[0], "update-herdr-core.sh") {
			t.Fatalf("unknown version %q/%q must warn, got %q", c[0], c[1], lines)
		}
	}
}

func TestHCMachineActionNameTaken(t *testing.T) {
	// Fixture entry 4 is named env-root-a1b2c3 but targets other-host; with
	// the real entry gone, that name blocks the add.
	list, err := parseHCMachineList([]byte(hcMachineListFixture))
	if err != nil {
		t.Fatal(err)
	}
	list.Machines = list.Machines[1:]
	action, m := hcMachineAction(list, "env-root-a1b2c3")
	if action != hcNameTaken || m.Target != "other-host" {
		t.Fatalf("action = %v (%q), want name taken by the other-host entry", action, m.Target)
	}
}

func TestLookupHCWithoutHome(t *testing.T) {
	notOnPath := func(string) (string, error) { return "", errors.New("not found") }
	if path, ok := lookupHC(notOnPath, ""); ok {
		t.Fatalf("an unknown home must not resolve a relative path, got %q", path)
	}
}

func TestRegisterHerdrMachinesWithoutAnyClientPrintsBothCommands(t *testing.T) {
	var stdout, stderr strings.Builder
	registerHerdrMachines(context.Background(), config{}, "env-root-a1b2c3", "", "", &stdout, &stderr)
	for _, want := range []string{
		"install the Herdr app or the herdr TUI",
		"app: hc machine add devenv-env-root-a1b2c3 --name env-root-a1b2c3",
		"TUI: herdr machine add devenv-env-root-a1b2c3 --label env-root-a1b2c3 --remote-session default",
	} {
		if !strings.Contains(stderr.String(), want) {
			t.Fatalf("stderr missing %q:\n%s", want, stderr.String())
		}
	}
	if stdout.Len() != 0 {
		t.Fatalf("expected no status output, got %q", stdout.String())
	}
}

// The Mac has the Herdr desktop app (hc) but not the herdr TUI: dev up
// registers with hc and does not ask for the TUI.
func TestRegisterHerdrMachinesWithOnlyTheAppUsesHC(t *testing.T) {
	dir := t.TempDir()
	hc := filepath.Join(dir, "hc")
	script := `#!/bin/sh
case "$1 $2" in
  "machine ls") echo '{"machines":[{"id":"1","name":"env-root-a1b2c3","target":"devenv-env-root-a1b2c3","state":"connected","version":"0.1.17"}]}' ;;
  *) exit 1 ;;
esac
`
	if err := os.WriteFile(hc, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr strings.Builder
	registerHerdrMachines(context.Background(), config{}, "env-root-a1b2c3", "", hc, &stdout, &stderr)
	if stderr.Len() != 0 {
		t.Fatalf("expected no notices, got:\n%s", stderr.String())
	}
	for _, want := range []string{"skip: herdr (TUI) is not installed", "ok: hc machine env-root-a1b2c3 is saved"} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout.String())
		}
	}
}
