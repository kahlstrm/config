package lab

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Lock allows one lab at a time per state root; clusters share the bridge
// address range and the host firewall rule.
func Lock(root string) (func() error, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(root, "lab.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("lab already in use: %w", err)
	}
	return f.Close, nil
}

// StateRoot is where runs keep their clusters and evidence.
func StateRoot(override string) (string, error) {
	root := override
	if root == "" {
		base := os.Getenv("XDG_STATE_HOME")
		if base == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return "", err
			}
			base = filepath.Join(home, ".local", "state")
		}
		root = filepath.Join(base, "talos-lab")
	}
	return filepath.Abs(root)
}
