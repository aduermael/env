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
	// hcNameTaken: no machine has this alias as its target, but another
	// machine already uses the name dev up would give it.
	hcNameTaken
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
	for _, m := range list.Machines {
		if m.Name == id {
			return hcNameTaken, m
		}
	}
	return hcAdd, hcMachine{}
}

// lookupHC finds hc on PATH, then at ~/.local/bin/hc, where the desktop
// app's installer puts it.
func lookupHC(lookPath func(string) (string, error), home string) (string, bool) {
	if path, err := lookPath("hc"); err == nil {
		return path, true
	}
	if home == "" {
		return "", false
	}
	candidate := filepath.Join(home, ".local", "bin", "hc")
	info, err := os.Stat(candidate)
	if err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
		return candidate, true
	}
	return "", false
}

// hcVersion reads the release out of `hc --version` output ("hc 0.1.17").
// Only the first line counts; later lines may carry build details.
func hcVersion(output string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(output), "\n")
	return strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "hc "))
}

// hcVersionMismatch compares the Mac's `hc --version` output with the
// container's.
func hcVersionMismatch(localOutput, remoteOutput string) (string, string, bool) {
	local := hcVersion(localOutput)
	remote := hcVersion(remoteOutput)
	if local == "" || remote == "" || local == remote {
		return local, remote, false
	}
	return local, remote, true
}

// ensureHCMachine registers the container with the Mac's herdr-core, which
// the Herdr desktop app uses.
func ensureHCMachine(ctx context.Context, cfg config, hcBin, id string, stdout, stderr io.Writer) {
	addLine := "hc " + strings.Join(hcMachineAddArgs(id), " ")

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
		hcVersionNotice(ctx, hcBin, id, stderr)
		return
	case hcNameTaken:
		notice(stderr, "hc already has a machine named %s that points at %s, not at %s", existing.Name, existing.Target, containerName(id))
		notice(stderr, "the container is up; rename or remove that machine, then register the container with:")
		notice(stderr, "  hc machine rm %s", existing.Name)
		notice(stderr, "  %s", addLine)
		return
	case hcReplace:
		notice(stderr, "hc machine %s points at a core that no longer exists (its volume was removed); replacing it", existing.Name)
		if err := runOnTerminal(ctx, hcBin, "machine", "rm", existing.Name); err != nil {
			notice(stderr, "hc machine rm failed: %v", err)
			notice(stderr, "remove it and register the container again with:")
			notice(stderr, "  hc machine rm %s", existing.Name)
			notice(stderr, "  %s", addLine)
			return
		}
	}

	status(cfg, stdout, "register: hc machine %s", id)
	notice(stderr, "if hc offers to copy its own build to the container, answer no: the image already ships hc, bump HERDR_CORE_VERSION with scripts/update-herdr-core.sh instead")
	if err := runOnTerminal(ctx, hcBin, hcMachineAddArgs(id)...); err != nil {
		notice(stderr, "hc machine add failed: %v", err)
		notice(stderr, "the container is up; register it with:")
		notice(stderr, "  %s", addLine)
		return
	}
	hcVersionNotice(ctx, hcBin, id, stderr)
}

// hcVersionNotice compares the Mac's hc with the one in the running
// container. It asks the container directly: the version the local core
// reports in `machine ls` is the one it last observed, which is stale right
// after a rebuild.
func hcVersionNotice(ctx context.Context, hcBin, id string, stderr io.Writer) {
	local, err := exec.CommandContext(ctx, hcBin, "--version").Output()
	if err != nil {
		return
	}
	remote, err := dockerOutput(ctx, "exec", containerName(id), "hc", "--version")
	if err != nil {
		return
	}
	if local, remote, mismatch := hcVersionMismatch(string(local), remote); mismatch {
		notice(stderr, "hc on this Mac is %s and the container has %s; bump the image pin with scripts/update-herdr-core.sh, then dev down and dev up", local, remote)
	}
}

// runOnTerminal runs a command on the user's terminal so it can prompt.
func runOnTerminal(ctx context.Context, bin string, args ...string) error {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if terminalFile(os.Stdin) {
		cmd.Stdin = os.Stdin
	}
	return cmd.Run()
}
