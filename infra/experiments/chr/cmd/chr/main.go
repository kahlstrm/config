package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/kahlstrm/config/infra/experiments/chr/internal/lab"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) (err error) {
	flags := flag.NewFlagSet("chr", flag.ContinueOnError)
	version := flags.String("version", "7.21.3", "RouterOS 7 release")
	state := flags.String("state", "", "state directory (default: $XDG_STATE_HOME/chr)")
	sshPort := flags.Int("ssh-port", 2222, "localhost SSH port")
	if err := flags.Parse(args); err != nil {
		return err
	}
	args = flags.Args()
	if len(args) == 0 {
		return errors.New("usage: chr [--version VERSION] [--state PATH] start|stop|fresh|status|ssh|run|scenarios")
	}
	if *sshPort < 1024 || *sshPort > 65535 {
		return errors.New("use an unprivileged SSH port")
	}
	if *state == "" {
		root := os.Getenv("XDG_STATE_HOME")
		if root == "" {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			root = filepath.Join(home, ".local/state")
		}
		*state = filepath.Join(root, "chr")
	}
	source := os.Getenv("CHR_SOURCE")
	if source == "" {
		source, err = os.Getwd()
		if err != nil {
			return err
		}
	}
	source, err = filepath.Abs(source)
	if err != nil {
		return err
	}
	scenarios := map[string]string{"bootstrap": "TestBootstrap", "dns-referral": "TestDNSReferral"}
	if args[0] == "scenarios" {
		fmt.Println("bootstrap\ndns-referral")
		return nil
	}
	if args[0] == "run" {
		if len(args) != 2 {
			return errors.New("choose a scenario: bootstrap, dns-referral")
		}
		test, ok := scenarios[args[1]]
		if !ok {
			return errors.New("choose a scenario: bootstrap, dns-referral")
		}
		root, err := filepath.Abs(*state)
		if err != nil {
			return err
		}
		cmd := exec.CommandContext(ctx, "go", "test", "-tags=integration", "-count=1", "-v", "-timeout=15m", "-run=^"+test+"$", ".")
		cmd.Dir = source
		cmd.Env = append(os.Environ(), "CHR_SOURCE="+source, "CHR_STATE="+root, "CHR_VERSION="+*version)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	}
	l, err := lab.New(*version, *state, *sshPort)
	if err != nil {
		return err
	}
	unlock, err := lab.Lock(l.Root)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, unlock()) }()
	switch args[0] {
	case "start":
		return l.Start(ctx)
	case "stop":
		return l.Stop(ctx)
	case "fresh":
		return l.Fresh(ctx)
	case "status":
		fmt.Printf("CHR %s: running=%t\nState: %s\n", l.Version, l.Running(), l.Directory)
		return nil
	case "ssh":
		if len(args) > 2 {
			return errors.New("pass the RouterOS command as one argument")
		}
		if len(args) == 2 {
			output, err := l.SSH(ctx, args[1])
			fmt.Print(output)
			return err
		}
		if !l.Running() {
			return errors.New("lab is stopped; run start first")
		}
		cmd := exec.CommandContext(ctx, "ssh", l.SSHArgs()...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	default:
		return fmt.Errorf("unknown command: %s", args[0])
	}
}
