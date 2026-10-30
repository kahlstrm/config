package lab

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ServerPort is where the lab's T3 server listens on the host's loopback,
// which the emulator reaches as 10.0.2.2.
const ServerPort = 3790

// EmulatorAddress is the server's address as the app types it.
var EmulatorAddress = "10.0.2.2:" + strconv.Itoa(ServerPort)

// Server is a throwaway T3 server with its own data directory.
type Server struct {
	Root string
	cmd  *exec.Cmd
}

// StartServer runs `t3 serve` from PATH, the agent environment's own package.
func StartServer(ctx context.Context, root string) (*Server, error) {
	project := filepath.Join(root, "project")
	if err := os.MkdirAll(project, 0o700); err != nil {
		return nil, err
	}
	log, err := os.Create(filepath.Join(root, "server.log"))
	if err != nil {
		return nil, err
	}
	defer log.Close()
	s := &Server{Root: root}
	s.cmd = exec.Command("t3", "serve", "--host", "127.0.0.1", "--port", strconv.Itoa(ServerPort), "--base-dir", filepath.Join(root, "home"))
	s.cmd.Dir = project
	s.cmd.Stdout, s.cmd.Stderr = log, log
	s.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := s.cmd.Start(); err != nil {
		return nil, err
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/.well-known/t3/environment", ServerPort)
	for deadline := time.Now().Add(2 * time.Minute); time.Now().Before(deadline); {
		if response, err := http.Get(url); err == nil {
			response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return s, nil
			}
		}
		if err := sleep(ctx, time.Second); err != nil {
			return nil, errors.Join(err, s.Stop())
		}
	}
	return nil, errors.Join(fmt.Errorf("T3 server did not start; see %s", log.Name()), s.Stop())
}

var tokenPattern = regexp.MustCompile(`token=([A-Z0-9]+)`)

// PairingCode mints a one-time code for the app.
func (s *Server) PairingCode(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "t3", "pair", "--base-dir", filepath.Join(s.Root, "home"), "--ttl", "30m", "--label", "lab").CombinedOutput()
	match := tokenPattern.FindSubmatch(out)
	if err != nil || match == nil {
		return "", fmt.Errorf("t3 pair: %w: %s", err, out)
	}
	return string(match[1]), nil
}

// Connections counts the server's established TCP connections.
func Connections(ctx context.Context) (int, error) {
	out, err := exec.CommandContext(ctx, "ss", "-Htn", "state", "established", fmt.Sprintf("( sport = :%d )", ServerPort)).Output()
	if err != nil {
		return 0, fmt.Errorf("ss: %w", err)
	}
	trimmed := strings.TrimSpace(string(out))
	if trimmed == "" {
		return 0, nil
	}
	return len(strings.Split(trimmed, "\n")), nil
}

// Stop ends the server.
func (s *Server) Stop() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}
	_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- s.cmd.Wait() }()
	select {
	case <-done:
		return nil
	case <-time.After(15 * time.Second):
		return syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
	}
}
