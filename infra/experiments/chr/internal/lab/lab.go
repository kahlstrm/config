package lab

import (
	"archive/zip"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var ansi = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]`)
var prompt = regexp.MustCompile(`\[admin@[^\]]+\] >\s*$`)
var routerError = regexp.MustCompile(`(?im)^\s*(failure:|syntax error|bad command name|expected (?:end of command|command name)|no such item|input does not match)`)

type CommandFunc func(context.Context, string, ...string) (string, error)

func Command(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		return stdout.String(), fmt.Errorf("%s: %w: %s", name, err, stderr.String())
	}
	return stdout.String(), nil
}

func Write(path, value string) error { return os.WriteFile(path, []byte(value), 0600) }

func Copy(source, target string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(target, data, 0600)
}

type Lab struct {
	EnableAPI                bool
	Version, Root, Directory string
	SSHPort                  int
	Run                      CommandFunc
	NetworkArgs              func(string) []string
	NetworkReady             func(context.Context) error
}

func New(version, root string, sshPort int) (*Lab, error) {
	if !regexp.MustCompile(`^7\.\d+(?:\.\d+)?(?:(?:rc|beta)\d+)?$`).MatchString(version) {
		return nil, fmt.Errorf("version must be a RouterOS 7 release number")
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if strings.ContainsAny(root, ",:\n") {
		return nil, errors.New("state directory cannot contain comma, colon, or newline")
	}
	l := &Lab{Version: version, Root: root, Directory: filepath.Join(root, version), SSHPort: sshPort, Run: Command}
	if err := os.MkdirAll(l.Directory, 0700); err != nil {
		return nil, err
	}
	if l.Running() {
		ports, err := os.ReadFile(l.Path("ports"))
		if err == nil {
			if _, err := fmt.Sscan(string(ports), &l.SSHPort); err != nil {
				return nil, err
			}
		}
	}
	return l, nil
}

func (l *Lab) Path(name string) string { return filepath.Join(l.Directory, name) }

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

func (l *Lab) Running() bool {
	data, err := os.ReadFile(l.Path("qemu.pid"))
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return false
	}
	command, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return false
	}
	expected := "file=" + l.Path("disk.qcow2") + ",format=qcow2,if=virtio"
	for _, arg := range strings.Split(string(command), "\x00") {
		if arg == expected {
			return true
		}
	}
	return false
}

func (l *Lab) SSHArgs() []string {
	return []string{"-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=3", "-o", "LogLevel=ERROR", "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=" + l.Path("known_hosts"), "-i", l.Path("id_ed25519"), "-p", strconv.Itoa(l.SSHPort), "admin@127.0.0.1"}
}

func (l *Lab) SSH(ctx context.Context, command string) (string, error) {
	if !l.Running() {
		return "", errors.New("lab is stopped; run start first")
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	output, err := l.Run(ctx, "ssh", append(l.SSHArgs(), command)...)
	output = strings.ReplaceAll(output, "\r", "")
	if err == nil && routerError.MatchString(output) {
		err = fmt.Errorf("RouterOS command failed: %s", output)
	}
	return output, err
}

func ValidateArchive(path, member string) error {
	archive, err := zip.OpenReader(path)
	if err != nil {
		return err
	}
	defer archive.Close()
	found := false
	for _, entry := range archive.File {
		if entry.Name == member {
			found = true
		}
		stream, err := entry.Open()
		if err != nil {
			return err
		}
		_, readErr := io.Copy(io.Discard, stream)
		closeErr := stream.Close()
		if err := errors.Join(readErr, closeErr); err != nil {
			return err
		}
	}
	if !found {
		return fmt.Errorf("archive missing %s", member)
	}
	return nil
}

func Download(ctx context.Context, run CommandFunc, url, destination, member string) error {
	if ValidateArchive(destination, member) == nil {
		return nil
	}
	if err := os.Remove(destination); err != nil && !os.IsNotExist(err) {
		return err
	}
	temporary := destination + ".part"
	var last error
	for attempt := 0; attempt < 3; attempt++ {
		_, last = run(ctx, "curl", "-fsSL", "--connect-timeout", "15", "--max-time", "300", url, "-o", temporary)
		if last == nil {
			last = ValidateArchive(temporary, member)
		}
		if last == nil {
			if err := os.Rename(temporary, destination); err != nil {
				return err
			}
			return nil
		}
		if err := os.Remove(temporary); err != nil && !os.IsNotExist(err) {
			return errors.Join(last, err)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	return fmt.Errorf("failed to download a valid CHR image: %w", last)
}

func (l *Lab) BaseImage(ctx context.Context) (string, error) {
	member := "chr-" + l.Version + ".img"
	store := os.Getenv("CHR_IMAGE")
	if store != "" {
		image := filepath.Join(store, member)
		if _, err := os.Stat(image); err == nil {
			images := filepath.Join(l.Root, "images")
			if err := os.MkdirAll(images, 0700); err != nil {
				return "", err
			}
			images, err = filepath.EvalSymlinks(images)
			if err != nil {
				return "", err
			}
			roots := filepath.Join(images, "nix-roots")
			if err := os.MkdirAll(roots, 0700); err != nil {
				return "", err
			}
			_, err = l.Run(ctx, "nix-store", "--realise", store, "--add-root", filepath.Join(roots, filepath.Base(store)), "--indirect")
			return image, err
		}
	}
	images := filepath.Join(l.Root, "images")
	if err := os.MkdirAll(images, 0700); err != nil {
		return "", err
	}
	archive := filepath.Join(images, member+".zip")
	if err := Download(ctx, l.Run, "https://download.mikrotik.com/routeros/"+l.Version+"/"+member+".zip", archive, member); err != nil {
		return "", err
	}
	image := filepath.Join(images, member)
	if _, err := os.Stat(image); err == nil {
		return image, nil
	}
	zipped, err := zip.OpenReader(archive)
	if err != nil {
		return "", err
	}
	defer zipped.Close()
	for _, entry := range zipped.File {
		if entry.Name != member {
			continue
		}
		input, err := entry.Open()
		if err != nil {
			return "", err
		}
		defer input.Close()
		temporary := image + ".part"
		defer os.Remove(temporary)
		output, err := os.OpenFile(temporary, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0400)
		if err != nil {
			return "", err
		}
		_, copyErr := io.Copy(output, input)
		if err := errors.Join(copyErr, output.Close()); err != nil {
			return "", err
		}
		return image, os.Rename(temporary, image)
	}
	return "", fmt.Errorf("image missing from validated archive")
}

func (l *Lab) Prepare(ctx context.Context) error {
	image, err := l.BaseImage(ctx)
	if err != nil {
		return err
	}
	if _, err := os.Stat(l.Path("disk.qcow2")); os.IsNotExist(err) {
		if _, err := l.Run(ctx, "qemu-img", "create", "-f", "qcow2", "-F", "raw", "-b", image, l.Path("disk.qcow2")); err != nil {
			return err
		}
	}
	if _, err := os.Stat(l.Path("id_ed25519")); os.IsNotExist(err) {
		_, err := l.Run(ctx, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", l.Path("id_ed25519"))
		return err
	}
	return nil
}

type ConsoleLogin struct {
	Password, loginPassword string
	passwordStage           int
}

func (s *ConsoleLogin) Respond(buffer string) (string, bool, error) {
	if strings.Contains(strings.ToLower(buffer), "login failed") {
		if s.loginPassword != "" {
			return "", false, errors.New("CHR login failed with the saved lab password")
		}
		s.loginPassword = s.Password
		index := strings.Index(strings.ToLower(buffer), "login failed")
		buffer = buffer[index+len("login failed"):]
	}
	switch {
	case strings.Contains(buffer, "\x1bZ"):
		return "\x1b[?1;2c", false, nil
	case strings.Contains(buffer, "Login:"):
		return "admin+ct\r", false, nil
	case strings.Contains(buffer, "Password:"):
		return s.loginPassword + "\r", false, nil
	case strings.Contains(buffer, "Do you want to see the software license"):
		return "n\r", false, nil
	case s.passwordStage == 0 && strings.Contains(buffer, "new password>"):
		s.passwordStage = 1
		return s.Password + "\r", false, nil
	case s.passwordStage == 1 && strings.Contains(buffer, "repeat new password>"):
		s.passwordStage = 2
		return s.Password + "\r", false, nil
	case prompt.MatchString(buffer):
		return "", true, nil
	default:
		return "", false, nil
	}
}

func readConsole(ctx context.Context, conn net.Conn, timeout time.Duration, respond func(string) (string, bool, error)) (string, error) {
	deadline := time.Now().Add(timeout)
	if parent, ok := ctx.Deadline(); ok && parent.Before(deadline) {
		deadline = parent
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return "", err
	}
	buffer := ""
	chunk := make([]byte, 65536)
	for {
		if err := ctx.Err(); err != nil {
			return buffer, err
		}
		n, err := conn.Read(chunk)
		if err != nil {
			return buffer, err
		}
		buffer += ansi.ReplaceAllString(strings.ToValidUTF8(string(chunk[:n]), "�"), "")
		response, done, err := respond(buffer)
		if err != nil || done {
			return buffer, err
		}
		if response != "" {
			if _, err := io.WriteString(conn, response); err != nil {
				return buffer, err
			}
			buffer = ""
		}
	}
}

func (l *Lab) Bootstrap(ctx context.Context) error {
	password, err := os.ReadFile(l.Path("password"))
	if os.IsNotExist(err) {
		data := make([]byte, 32)
		if _, err := rand.Read(data); err != nil {
			return err
		}
		password = []byte(base64.RawURLEncoding.EncodeToString(data))
		if err := Write(l.Path("password"), string(password)); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	key, err := os.ReadFile(l.Path("id_ed25519.pub"))
	if err != nil {
		return err
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", l.Path("serial.sock"))
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := io.WriteString(conn, "\r"); err != nil {
		return err
	}
	login := ConsoleLogin{Password: string(password)}
	if _, err := readConsole(ctx, conn, 90*time.Second, login.Respond); err != nil {
		return fmt.Errorf("bootstrapping console: %w", err)
	}
	services := "/ip/service/disable [find where dynamic=no and name!=ssh]"
	if l.EnableAPI {
		services = "/ip/service/disable [find where dynamic=no and name!=ssh and name!=api]"
	}
	for _, command := range []string{
		"/system/identity/set name=chr-lab",
		services,
		fmt.Sprintf(`/file/add name=lab.pub type=file contents="%s"`, strings.TrimSpace(string(key))),
		"/user/ssh-keys/import user=admin public-key-file=lab.pub",
		`/file/remove [find name="lab.pub"]`,
	} {
		if _, err := io.WriteString(conn, command+"\r"); err != nil {
			return err
		}
		output, err := readConsole(ctx, conn, 10*time.Second, func(buffer string) (string, bool, error) { return "", prompt.MatchString(buffer), nil })
		if err != nil {
			return fmt.Errorf("console command timed out: %s: %w", strings.Fields(command)[0], err)
		}
		if routerError.MatchString(strings.ReplaceAll(output, "\r", "")) {
			return fmt.Errorf("console command failed: %s", output)
		}
	}
	return nil
}

func (l *Lab) DefaultNetworkArgs(capture string) []string {
	return []string{"-netdev", fmt.Sprintf("user,id=lab,hostfwd=tcp:127.0.0.1:%d-:22", l.SSHPort), "-device", "virtio-net-pci,netdev=lab", "-object", "filter-dump,id=capture,netdev=lab,file=" + capture}
}

func (l *Lab) Start(ctx context.Context) error {
	if l.Running() {
		fmt.Printf("CHR %s is already running\n", l.Version)
		return nil
	}
	if err := l.Prepare(ctx); err != nil {
		return err
	}
	for _, name := range []string{"serial.sock", "monitor.sock", "qemu.pid"} {
		if err := os.Remove(l.Path(name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	if err := os.MkdirAll(l.Path("captures"), 0700); err != nil {
		return err
	}
	capture := l.Path(fmt.Sprintf("captures/%d.pcap", time.Now().UnixNano()))
	network := l.DefaultNetworkArgs
	if l.NetworkArgs != nil {
		network = l.NetworkArgs
	}
	args := []string{"-name", "chr-" + l.Version, "-enable-kvm", "-cpu", "host", "-m", "512", "-smp", "2", "-drive", "file=" + l.Path("disk.qcow2") + ",format=qcow2,if=virtio"}
	args = append(args, network(capture)...)
	args = append(args, "-display", "none", "-chardev", "socket,id=serial,path="+l.Path("serial.sock")+",server=on,wait=off,logfile="+l.Path("serial.log")+",logappend=on", "-serial", "chardev:serial", "-monitor", "unix:"+l.Path("monitor.sock")+",server=on,wait=off", "-pidfile", l.Path("qemu.pid"), "-daemonize")
	if _, err := l.Run(ctx, "qemu-system-x86_64", args...); err != nil {
		return err
	}
	if l.NetworkReady != nil {
		if err := l.NetworkReady(ctx); err != nil {
			return err
		}
	}
	if err := Write(l.Path("ports"), fmt.Sprintf("%d\n", l.SSHPort)); err != nil {
		return err
	}
	if _, err := os.Stat(l.Path("configured")); os.IsNotExist(err) {
		if err := l.Bootstrap(ctx); err != nil {
			return err
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	for ctx.Err() == nil {
		output, err := l.SSH(ctx, "/system/resource/print")
		if err == nil {
			if !strings.Contains(output, "version: "+l.Version+" ") {
				return fmt.Errorf("unexpected RouterOS version: %s", output)
			}
			if err := Write(l.Path("configured"), ""); err != nil {
				return err
			}
			fmt.Printf("CHR %s ready: SSH 127.0.0.1:%d\nState: %s\nCapture: %s\n", l.Version, l.SSHPort, l.Directory, capture)
			return nil
		}
		if routerError.MatchString(output) {
			return err
		}
		if err := Sleep(ctx, time.Second); err != nil {
			break
		}
	}
	return errors.New("CHR started but SSH did not become ready; VM left running for diagnosis")
}

func Sleep(ctx context.Context, delay time.Duration) error {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (l *Lab) Monitor(ctx context.Context, command string) (string, error) {
	if !l.Running() {
		return "", errors.New("lab is stopped; run start first")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", l.Path("monitor.sock"))
	if err != nil {
		return "", err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return "", err
	}
	read := func() (string, error) {
		buffer := ""
		chunk := make([]byte, 65536)
		for !strings.HasSuffix(buffer, "(qemu) ") {
			n, err := conn.Read(chunk)
			if err != nil {
				return buffer, err
			}
			buffer += string(chunk[:n])
		}
		return ansi.ReplaceAllString(buffer, ""), nil
	}
	if _, err := read(); err != nil {
		return "", err
	}
	if _, err := io.WriteString(conn, command+"\n"); err != nil {
		return "", err
	}
	output, err := read()
	if err == nil && regexp.MustCompile(`(?im)(error:|could not|invalid |unknown command|not found)`).MatchString(output) {
		err = fmt.Errorf("QEMU command failed: %s", output)
	}
	return output, err
}

func ForwardPort(output, protocol string, guestPort int) (int, error) {
	ports := []int{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 8 && fields[0] == strings.ToUpper(protocol)+"[HOST_FORWARD]" && fields[2] == "127.0.0.1" && fields[5] == strconv.Itoa(guestPort) {
			port, err := strconv.Atoi(fields[3])
			if err != nil {
				return 0, err
			}
			ports = append(ports, port)
		}
	}
	if len(ports) != 1 {
		return 0, fmt.Errorf("expected one %s forward to guest port %d: %v", protocol, guestPort, ports)
	}
	return ports[0], nil
}

func (l *Lab) ForwardedPort(ctx context.Context, protocol string, guestPort int) (int, error) {
	output, err := l.Monitor(ctx, "info usernet")
	if err != nil {
		return 0, err
	}
	return ForwardPort(output, protocol, guestPort)
}

func (l *Lab) Forward(ctx context.Context, protocol string, hostPort, guestPort int, address string) (func() error, error) {
	if protocol != "tcp" && protocol != "udp" {
		return nil, errors.New("forward protocol must be tcp or udp")
	}
	if hostPort < 0 || hostPort > 65535 || (hostPort > 0 && hostPort < 1024) || guestPort < 1 || guestPort > 65535 {
		return nil, errors.New("invalid forwarding ports")
	}
	if protocol == "tcp" && hostPort != 0 && hostPort == l.SSHPort {
		return nil, errors.New("forward cannot use the SSH management port")
	}
	if _, err := l.Monitor(ctx, fmt.Sprintf("hostfwd_add lab %s:127.0.0.1:%d-%s:%d", protocol, hostPort, address, guestPort)); err != nil {
		return nil, err
	}
	if hostPort == 0 {
		port, err := l.ForwardedPort(ctx, protocol, guestPort)
		if err != nil {
			return nil, err
		}
		hostPort = port
	}
	return func() error {
		_, err := l.Monitor(context.Background(), fmt.Sprintf("hostfwd_remove lab %s:127.0.0.1:%d", protocol, hostPort))
		return err
	}, nil
}

func (l *Lab) Stop(ctx context.Context) error {
	if !l.Running() {
		return nil
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", l.Path("monitor.sock"))
	if err != nil {
		return err
	}
	if err := conn.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		conn.Close()
		return err
	}
	_, writeErr := io.WriteString(conn, "system_powerdown\n")
	if err := errors.Join(writeErr, conn.Close()); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	for l.Running() {
		if err := Sleep(ctx, 250*time.Millisecond); err != nil {
			return errors.New("CHR did not shut down after ACPI request; left running")
		}
	}
	fmt.Println("CHR stopped; disk and captures retained")
	return nil
}

func (l *Lab) Fresh(ctx context.Context) error {
	if err := l.Stop(ctx); err != nil {
		return err
	}
	archive := l.Path(fmt.Sprintf("archives/%d", time.Now().UnixNano()))
	if err := os.MkdirAll(archive, 0700); err != nil {
		return err
	}
	for _, name := range []string{"disk.qcow2", "known_hosts", "password", "configured", "ports"} {
		if err := os.Rename(l.Path(name), filepath.Join(archive, name)); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	fmt.Println("Previous lab disk and configuration archived in", archive)
	return l.Start(ctx)
}

func RootReply(output string) error {
	if strings.Contains(output, "status: NOERROR") {
		_, answer, _ := strings.Cut(output, ";; ANSWER SECTION:")
		answer, _, _ = strings.Cut(answer, ";;")
		for _, line := range strings.Split(answer, "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 5 && fields[0] == "." && fields[2] == "IN" && fields[3] == "NS" {
				return nil
			}
		}
	}
	return errors.New("expected a NOERROR reply with at least one root NS answer")
}

func NegativeReply(output string) (int, int, error) {
	if !strings.Contains(output, "status: NOERROR") || !regexp.MustCompile(`ANSWER: 0\b`).MatchString(output) {
		return 0, 0, errors.New("expected a NOERROR reply with no AAAA answers")
	}
	_, authority, _ := strings.Cut(output, ";; AUTHORITY SECTION:")
	authority, _, _ = strings.Cut(authority, ";;")
	roots, soa := 0, 0
	for _, line := range strings.Split(authority, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		if fields[0] == "." && fields[3] == "NS" {
			roots++
		}
		if fields[3] == "SOA" {
			soa++
		}
	}
	return roots, soa, nil
}
