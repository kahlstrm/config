package main

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
)

var systemctlPath, journalctlPath, homeDirectory string

func usage() {
	fmt.Fprintln(os.Stderr, "Usage: steam-session {status|stop|restart|logs} {gamescope|steam|sunshine}")
	fmt.Fprintln(os.Stderr, "       steam-session {status|restart|logs} {wireplumber|pipewire|pipewire-pulse}")
	os.Exit(2)
}

func main() {
	if len(os.Args) != 3 {
		usage()
	}
	action, service := os.Args[1], os.Args[2]
	switch action {
	case "status", "stop", "restart", "logs":
	default:
		usage()
	}

	var unit string
	switch service {
	case "gamescope":
		unit = "gamescope-session.service"
		if action == "stop" || action == "restart" {
			unit = "gamescope-session.target"
		}
	case "steam":
		unit = "steam-launcher.service"
	case "sunshine":
		unit = "sunshine.service"
	case "wireplumber", "pipewire", "pipewire-pulse":
		if action == "stop" {
			usage()
		}
		unit = service + ".service"
	default:
		usage()
	}

	runtimeDir := "/run/user/" + strconv.Itoa(os.Geteuid())
	environment := []string{
		"HOME=" + homeDirectory,
		"XDG_RUNTIME_DIR=" + runtimeDir,
		"DBUS_SESSION_BUS_ADDRESS=unix:path=" + runtimeDir + "/bus",
		"SYSTEMD_PAGER=cat",
		"SYSTEMD_COLORS=0",
	}
	path := systemctlPath
	arguments := []string{path, "--user", "--no-pager", "--no-ask-password", action, unit}
	if action == "logs" {
		path = journalctlPath
		arguments = []string{path, "--user", "--no-pager", "--lines=100", "--user-unit", unit}
	}
	if err := syscall.Exec(path, arguments, environment); err != nil {
		fmt.Fprintln(os.Stderr, "steam-session:", err)
		os.Exit(1)
	}
}
