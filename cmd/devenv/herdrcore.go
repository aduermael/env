package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// hc (herdr-core) is the server the Herdr desktop app talks to. The Mac's
// local core keeps a list of SSH machines; dev up adds the worktree
// container to it under the same alias the Herdr TUI uses.

const hcDifferentCorePrefix = "a different core answers there"

type hcMachine struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Target  string `json:"target"`
	State   string `json:"state"`
	Version string `json:"version"`
	Why     string `json:"why"`
}

type hcMachineList struct {
	Machines []hcMachine `json:"machines"`
}

type hcAction int

const (
	// hcRegistered: the alias is saved and usable.
	hcRegistered hcAction = iota
	// hcAdd: no machine has this alias as its target.
	hcAdd
	// hcReplace: the alias is saved, but the core identity on the volume
	// changed, so the entry can never connect again.
	hcReplace
)

func hcMachineAddArgs(id string) []string {
	return []string{"machine", "add", containerName(id), "--name", id}
}

func parseHCMachineList(data []byte) (hcMachineList, error) {
	var list hcMachineList
	if err := json.Unmarshal(data, &list); err != nil {
		return hcMachineList{}, fmt.Errorf("parse hc machine ls: %w", err)
	}
	return list, nil
}

// hcMachineAction decides what dev up has to do for this id. It matches the
// target, not the name: a renamed machine is still the same machine.
func hcMachineAction(list hcMachineList, id string) (hcAction, hcMachine) {
	for _, m := range list.Machines {
		if m.Target != containerName(id) {
			continue
		}
		if m.State == "unreachable" && strings.HasPrefix(m.Why, hcDifferentCorePrefix) {
			return hcReplace, m
		}
		return hcRegistered, m
	}
	return hcAdd, hcMachine{}
}

// lookupHC finds hc on PATH, then at ~/.local/bin/hc, where the desktop
// app's installer puts it.
func lookupHC(lookPath func(string) (string, error), home string) (string, bool) {
	if path, err := lookPath("hc"); err == nil {
		return path, true
	}
	candidate := filepath.Join(home, ".local", "bin", "hc")
	info, err := os.Stat(candidate)
	if err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
		return candidate, true
	}
	return "", false
}

// hcVersionMismatch compares the Mac's `hc --version` line with the version
// the local core last observed on the machine.
func hcVersionMismatch(localVersionLine, remoteVersion string) (string, string, bool) {
	local := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(localVersionLine), "hc "))
	remote := strings.TrimSpace(remoteVersion)
	if local == "" || remote == "" || local == remote {
		return local, remote, false
	}
	return local, remote, true
}

// ensureHCMachine registers the container with the Mac's herdr-core. It
// never fails dev up: the container stays up and the user gets the command.
func ensureHCMachine(ctx context.Context, cfg config, id string, stdout, stderr io.Writer) {
	addLine := "hc " + strings.Join(hcMachineAddArgs(id), " ")
	home, _ := os.UserHomeDir()
	hcBin, ok := lookupHC(exec.LookPath, home)
	if !ok {
		notice(stderr, "hc (herdr-core) is not installed on this Mac; the Herdr desktop app installs it, or run: curl -fsSL https://releases.herdr.dev/core/install.sh | sh")
		notice(stderr, "then register the container with:")
		notice(stderr, "  %s", addLine)
		return
	}

	action := hcAdd
	var existing hcMachine
	if out, err := exec.CommandContext(ctx, hcBin, "machine", "ls", "--json").Output(); err == nil {
		if list, parseErr := parseHCMachineList(out); parseErr == nil {
			action, existing = hcMachineAction(list, id)
		}
	}

	switch action {
	case hcRegistered:
		status(cfg, stdout, "ok: hc machine %s is saved", id)
		hcVersionNotice(ctx, hcBin, existing, stderr)
		return
	case hcReplace:
		notice(stderr, "hc machine %s points at a core that no longer exists (its volume was removed); replacing it", existing.Name)
		if err := runHC(ctx, hcBin, "machine", "rm", existing.Name); err != nil {
			notice(stderr, "hc machine rm failed: %v", err)
			notice(stderr, "remove it and register the container again with:")
			notice(stderr, "  hc machine rm %s", existing.Name)
			notice(stderr, "  %s", addLine)
			return
		}
	}

	status(cfg, stdout, "register: hc machine %s", id)
	notice(stderr, "if hc offers to copy its own build to the container, answer no: the image already ships hc, bump HERDR_CORE_VERSION with scripts/update-herdr-core.sh instead")
	if err := runHC(ctx, hcBin, hcMachineAddArgs(id)...); err != nil {
		notice(stderr, "hc machine add failed: %v", err)
		notice(stderr, "the container is up; register it with:")
		notice(stderr, "  %s", addLine)
		return
	}

	if out, err := exec.CommandContext(ctx, hcBin, "machine", "ls", "--json").Output(); err == nil {
		if list, parseErr := parseHCMachineList(out); parseErr == nil {
			if action, m := hcMachineAction(list, id); action == hcRegistered {
				hcVersionNotice(ctx, hcBin, m, stderr)
			}
		}
	}
}

func hcVersionNotice(ctx context.Context, hcBin string, m hcMachine, stderr io.Writer) {
	out, err := exec.CommandContext(ctx, hcBin, "--version").Output()
	if err != nil {
		return
	}
	if local, remote, mismatch := hcVersionMismatch(string(out), m.Version); mismatch {
		notice(stderr, "hc on this Mac is %s and the container has %s; bump the image pin with scripts/update-herdr-core.sh, then dev down and dev up", local, remote)
	}
}

// runHC runs hc on the user's terminal so it can prompt.
func runHC(ctx context.Context, hcBin string, args ...string) error {
	cmd := exec.CommandContext(ctx, hcBin, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if terminalFile(os.Stdin) {
		cmd.Stdin = os.Stdin
	}
	return cmd.Run()
}
