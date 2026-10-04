package lab

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type BootstrapLab struct {
	*Lab
	Name, Address, Prefix, Transit, Source string
	Listen                                 bool
	HTTPSPort                              int
}

func NewBootstrap(version, sharedRoot, runRoot, name, source, transit string, listen bool) (*BootstrapLab, error) {
	l, err := New(version, filepath.Join(runRoot, name), 0)
	if err != nil {
		return nil, err
	}
	address := "10.10.10.1"
	if name == "stationary" {
		address = "10.1.1.1"
	}
	router := &BootstrapLab{Lab: l, Name: name, Address: address, Prefix: strings.TrimSuffix(address, ".1"), Transit: transit, Source: source, Listen: listen}
	images := filepath.Join(sharedRoot, "images")
	if err := os.MkdirAll(images, 0700); err != nil {
		return nil, err
	}
	if err := os.Symlink(images, filepath.Join(l.Root, "images")); err != nil {
		return nil, err
	}
	l.NetworkArgs = router.networkArgs
	l.NetworkReady = func(ctx context.Context) error {
		var err error
		l.SSHPort, err = l.ForwardedPort(ctx, "tcp", 22)
		if err != nil {
			return err
		}
		router.HTTPSPort, err = l.ForwardedPort(ctx, "tcp", 443)
		return err
	}
	return router, nil
}

func (l *BootstrapLab) networkArgs(capture string) []string {
	args := []string{}
	// The factory DHCP client uses ether1; the reset wrapper maps it to the RB5009 LAN port.
	for index := 1; index <= 9; index++ {
		ident, backend := fmt.Sprintf("port%d", index), ""
		switch index {
		case 1:
			ident = "lab"
			backend = fmt.Sprintf("user,id=lab,net=%s.0/24,host=%s.254,dhcpstart=%s.200,hostfwd=tcp:127.0.0.1:%d-%s.200:22,hostfwd=tcp:127.0.0.1:%d-%s:443", l.Prefix, l.Prefix, l.Prefix, l.SSHPort, l.Prefix, l.HTTPSPort, l.Address)
		case 2:
			mode := "off"
			if l.Listen {
				mode = "on"
			}
			backend = fmt.Sprintf("stream,id=%s,server=%s,addr.type=unix,addr.path=%s", ident, mode, l.Transit)
		case 8:
			backend = "user,id=" + ident + ",net=192.0.2.0/24"
		default:
			backend = fmt.Sprintf("hubport,id=%s,hubid=%d", ident, index)
		}
		routerID := 2
		if l.Listen {
			routerID = 1
		}
		args = append(args, "-netdev", backend, "-device", fmt.Sprintf("virtio-net-pci,netdev=%s,mac=52:54:00:00:%02x:%02x", ident, routerID, index))
	}
	return append(args, "-object", "filter-dump,id=capture,netdev=lab,file="+capture)
}

func (l *BootstrapLab) Upload(ctx context.Context, path, name string) error {
	args := l.SSHArgs()
	for i, arg := range args {
		if arg == "-p" {
			args[i] = "-P"
		}
	}
	args[len(args)-1] += ":" + name
	args = append([]string{"-O"}, append(args[:len(args)-1], path, args[len(args)-1])...)
	if _, err := l.Run(ctx, "scp", args...); err != nil {
		return err
	}
	stat, err := os.Stat(path)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		output, err := l.SSH(ctx, fmt.Sprintf(`:put [/file get [find name="%s"] size]`, name))
		if err == nil && strings.TrimSpace(output) == strconv.FormatInt(stat.Size(), 10) {
			return nil
		}
		if err := Sleep(ctx, 500*time.Millisecond); err != nil {
			break
		}
	}
	return fmt.Errorf("%s: upload not visible: %s", l.Name, name)
}

func (l *BootstrapLab) Reset(ctx context.Context) error {
	script := filepath.Join(l.Source, "../../local-networking/bootstrap/generated", l.Name+".rsc")
	if err := Copy(script, l.Path("bootstrap.rsc")); err != nil {
		return err
	}
	if err := l.Upload(ctx, l.Path("bootstrap.rsc"), "bootstrap.rsc"); err != nil {
		return err
	}
	wrapper := ":delay 5s\n/interface ethernet set [find default-name=ether1] name=temporary-lan\n/interface ethernet set [find default-name=ether2] name=ether1\n/interface ethernet set [find default-name=ether1] name=ether2\n/interface ethernet set [find default-name=ether9] name=sfp-sfpplus1\n/ip dhcp-client remove [find]\n/import file-name=bootstrap.rsc\n"
	if err := Write(l.Path("reset.rsc"), wrapper); err != nil {
		return err
	}
	contents := strings.NewReplacer("\\", "\\\\", `"`, `\"`, "\n", `\n`).Replace(wrapper)
	// RouterOS can acknowledge SCP before its file index exposes a reset hook.
	// Create that hook through the router itself after the bootstrap upload is visible.
	if _, err := l.SSH(ctx, "/file remove [find name=reset.rsc]; /file remove [find name=boostrap.txt]"); err != nil {
		return err
	}
	if _, err := l.SSH(ctx, `/file add name=reset.rsc type=file contents="`+contents+`"`); err != nil {
		return err
	}
	fmt.Println(l.Name + ": resetting into production bootstrap")
	output, err := l.SSH(ctx, "/system reset-configuration no-defaults=yes keep-users=yes skip-backup=yes run-after-reset=reset.rsc")
	if err != nil {
		if writeErr := Write(l.Path("reset-request.log"), output+"\n"+err.Error()); writeErr != nil {
			return errors.Join(err, writeErr)
		}
		if strings.Contains(output+err.Error(), "input does not match") {
			return fmt.Errorf("%s: RouterOS rejected reset.rsc: %w", l.Name, err)
		}
	}
	if _, err := l.Monitor(ctx, fmt.Sprintf("hostfwd_remove lab tcp:127.0.0.1:%d", l.SSHPort)); err != nil {
		return err
	}
	if _, err := l.Monitor(ctx, "hostfwd_add lab tcp:127.0.0.1:0-"+l.Address+":22"); err != nil {
		return err
	}
	l.SSHPort, err = l.ForwardedPort(ctx, "tcp", 22)
	if err != nil {
		return err
	}
	if err := Write(l.Path("ports"), fmt.Sprintf("%d\n", l.SSHPort)); err != nil {
		return err
	}
	if err := Sleep(ctx, 10*time.Second); err != nil {
		return err
	}
	if err := os.Remove(l.Path("known_hosts")); err != nil && !os.IsNotExist(err) {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 240*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		serial, err := os.ReadFile(l.Path("serial.log"))
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		if strings.Contains(string(serial), "error while running run-after-reset script") {
			return fmt.Errorf("%s: reset script failed; see serial.log", l.Name)
		}
		output, err := l.SSH(ctx, `:put [/file get [find name="boostrap.txt"] contents]`)
		if err == nil && strings.Contains(output, "bootstrap_script_finished") {
			global, err := l.SSH(ctx, `:put [:len [/system script environment find where name="isLocalBridgeCreated"]]`)
			if err == nil && strings.TrimSpace(global) == "0" {
				if err := Write(l.Path("bootstrap.log"), output); err != nil {
					return err
				}
				fmt.Println(l.Name + ": bootstrap completed, management reachable")
				return nil
			}
		}
		if err := Sleep(ctx, 3*time.Second); err != nil {
			break
		}
	}
	return fmt.Errorf("%s: bootstrap failed; inspect %s", l.Name, l.Directory)
}

func (l *BootstrapLab) FirewallExport(ctx context.Context) (string, error) {
	output, err := l.SSH(ctx, "/export terse")
	if err != nil {
		return "", err
	}
	lines := []string{}
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "/ip firewall ") || strings.HasPrefix(line, "/ipv6 firewall ") {
			lines = append(lines, strings.TrimSpace(line))
		}
	}
	return strings.Join(lines, "\n"), nil
}

func (l *BootstrapLab) Check(ctx context.Context, command, expected, label string) error {
	output, err := l.SSH(ctx, command)
	if err != nil {
		return err
	}
	output = strings.TrimSpace(output)
	f, err := os.OpenFile(l.Path("checks.txt"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, writeErr := fmt.Fprintf(f, "%s\n%s\n%s\n\n", label, command, output)
	if err := errors.Join(writeErr, f.Close()); err != nil {
		return err
	}
	if output != expected {
		return fmt.Errorf("%s: %s: expected %q, got %q", l.Name, label, expected, output)
	}
	fmt.Printf("%s: PASS %s\n", l.Name, label)
	return nil
}

func (l *BootstrapLab) Verify(ctx context.Context) (err error) {
	checks := []struct{ command, expected, label string }{
		{":put [/ipv6 settings get disable-ipv6]", "true", "IPv6 disabled"},
		{":put [:len [/ipv6 nd find where disabled=no]]", "0", "no router advertisements"},
		{":put [:len [/ip dns static find where type=AAAA and disabled=no]]", "0", "no enabled router AAAA records"},
		{`:put [:resolve "stationary.networking.kalski.xyz" type=ipv4]`, "10.1.1.1", "DNS A record for stationary"},
		{`:put [:resolve "kuberack.networking.kalski.xyz" type=ipv4]`, "10.10.10.1", "DNS A record for kuberack"},
		{":put [/ip service get www-ssl disabled]", "false", "HTTPS management enabled"},
		{":put [/certificate get [find name=self] private-key]", "true", "HTTPS certificate has private key"},
	}
	for _, check := range checks {
		if err := l.Check(ctx, check.command, check.expected, check.label); err != nil {
			return err
		}
	}
	remove, err := l.Forward(ctx, "udp", 0, 53, l.Address)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, remove()) }()
	port, err := l.ForwardedPort(ctx, "udp", 53)
	if err != nil {
		return err
	}
	for _, record := range []struct{ name, address string }{{"stationary", "10.1.1.1"}, {"kuberack", "10.10.10.1"}} {
		output, err := l.Run(ctx, "dig", "@127.0.0.1", "-p", strconv.Itoa(port), record.name+".networking.kalski.xyz", "A", "+short", "+time=2", "+tries=1")
		if err != nil {
			return err
		}
		if strings.TrimSpace(output) != record.address {
			return fmt.Errorf("%s: external DNS query for %s failed: %s", l.Name, record.name, output)
		}
	}
	peer := "10.1.1.1"
	if l.Listen {
		peer = "10.10.10.1"
	}
	command := fmt.Sprintf(`:local received 0; :foreach reply in=[/ping address=%s src-address=%s count=3 interval=200ms as-value] do={:if ([:typeof ($reply->"time")] != "nil") do={:set received ($received + 1)}}; :put $received`, peer, l.Address)
	if err := l.Check(ctx, command, "3", "bidirectional routed IPv4 management"); err != nil {
		return err
	}
	output, err := l.SSH(ctx, "/export terse")
	if err != nil {
		return err
	}
	return Write(l.Path("export.rsc"), output)
}
