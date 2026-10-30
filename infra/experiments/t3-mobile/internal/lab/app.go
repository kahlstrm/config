package lab

import (
	"context"
	"fmt"
	"time"
)

// Package is the production app's Android package.
const Package = "com.t3tools.t3code"

// OfflineLabel is the home header the app shows while the platform reports
// no network.
const OfflineLabel = "You are offline"

// Launch brings the app to the foreground, as tapping its icon does.
func (d *Device) Launch(ctx context.Context) error {
	return d.Shell(ctx, "monkey", "-p", Package, "-c", "android.intent.category.LAUNCHER", "1")
}

// Home sends the app to the background.
func (d *Device) Home(ctx context.Context) error {
	return d.Shell(ctx, "input", "keyevent", "HOME")
}

// Pair adds the server through the app's manual pairing form; release builds
// ignore pairing links.
func (d *Device) Pair(ctx context.Context, server *Server) error {
	code, err := server.PairingCode(ctx)
	if err != nil {
		return err
	}
	if err := d.Launch(ctx); err != nil {
		return err
	}
	if _, err := d.WaitFor(ctx, time.Minute, Labelled("Chats")); err != nil {
		return fmt.Errorf("app did not start: %w", err)
	}
	if err := d.Shell(ctx, "am", "start", "-a", "android.intent.action.VIEW", "-d", "t3code://settings/environment-new", Package); err != nil {
		return err
	}
	for _, field := range []struct{ label, value string }{{"Address", EmulatorAddress}, {"Code", code}} {
		node, err := d.WaitFor(ctx, 30*time.Second, func(n Node) bool { return n.Desc == field.label && n.Text != field.label })
		if err != nil {
			return fmt.Errorf("pairing form field %s: %w", field.label, err)
		}
		if err := d.Tap(ctx, node); err != nil {
			return err
		}
		if err := d.Shell(ctx, "input", "text", field.value); err != nil {
			return err
		}
	}
	// Escape closes the keyboard; the toolbar's check mark submits.
	if err := d.Shell(ctx, "input", "keyevent", "111"); err != nil {
		return err
	}
	submit, err := d.WaitFor(ctx, 10*time.Second, func(n Node) bool { return n.Desc == "Add environment" && n.Bounds.Min.Y < 300 })
	if err != nil {
		return err
	}
	if err := d.Tap(ctx, submit); err != nil {
		return err
	}
	if err := WaitConnected(ctx, time.Minute); err != nil {
		return fmt.Errorf("pairing: %w", err)
	}
	chats, err := d.WaitFor(ctx, 30*time.Second, Labelled("Chats"))
	if err != nil {
		return err
	}
	return d.Tap(ctx, chats)
}

// WaitConnected waits for the app to hold a connection to the server.
func WaitConnected(ctx context.Context, timeout time.Duration) error {
	for deadline := time.Now().Add(timeout); ; {
		count, err := Connections(ctx)
		if err != nil {
			return err
		}
		if count > 0 {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("no connection to the server after %s", timeout)
		}
		if err := sleep(ctx, time.Second); err != nil {
			return err
		}
	}
}

// SetNetworkBlocked blocks or unblocks the app's network as Android does for
// background apps, through the debugging firewall chain.
func (d *Device) SetNetworkBlocked(ctx context.Context, blocked bool) error {
	if err := d.Shell(ctx, "cmd", "connectivity", "set-chain3-enabled", "true"); err != nil {
		return err
	}
	return d.Shell(ctx, "cmd", "connectivity", "set-package-networking-enabled", fmt.Sprint(!blocked), Package)
}

// State is what the app shows and holds at one moment.
type State struct {
	Offline     bool
	Connections int
}

func (s State) String() string {
	return fmt.Sprintf("offline header=%t, server connections=%d", s.Offline, s.Connections)
}

// Observe reads the app's state.
func (d *Device) Observe(ctx context.Context) (State, error) {
	offline, err := d.Shows(ctx, OfflineLabel)
	if err != nil {
		return State{}, err
	}
	count, err := Connections(ctx)
	return State{Offline: offline, Connections: count}, err
}

// Sleep pauses the scenario.
func Sleep(ctx context.Context, duration time.Duration) error { return sleep(ctx, duration) }
