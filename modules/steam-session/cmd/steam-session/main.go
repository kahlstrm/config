package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func main() {
	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "steam-session:", err)
		os.Exit(1)
	}
	control := filepath.Join(filepath.Dir(executable), "steam-session-control")
	arguments := append([]string{
		"sudo", "-n", "-H", "-u", "steam-machine", "--", control,
	}, os.Args[1:]...)
	if err := syscall.Exec("/run/wrappers/bin/sudo", arguments, os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, "steam-session:", err)
		os.Exit(1)
	}
}
