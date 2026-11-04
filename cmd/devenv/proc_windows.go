//go:build windows

package main

import (
	"os"
	"os/exec"
)

func detachCommand(cmd *exec.Cmd) {}

// lockFile has no cross-process lock on Windows; devenv only runs on macOS.
func lockFile(path string) (func(), error) {
	file, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	return func() { file.Close() }, nil
}
