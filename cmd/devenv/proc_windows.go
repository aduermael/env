//go:build windows

package main

import "os/exec"

func detachCommand(cmd *exec.Cmd) {}
