package lab

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestImageCacheRetriesAndValidatesDownloads(t *testing.T) {
	for _, failure := range []string{"interrupted", "invalid", "wrong member"} {
		t.Run(failure, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "chr.zip")
			calls := 0
			run := func(_ context.Context, _ string, args ...string) (string, error) {
				calls++
				temporary := args[len(args)-1]
				if _, err := os.Stat(temporary); !os.IsNotExist(err) {
					t.Fatal("partial download retained between attempts")
				}
				if calls == 1 && failure != "wrong member" {
					if err := Write(temporary, "partial"); err != nil {
						t.Fatal(err)
					}
					if failure == "interrupted" {
						return "", errors.New("interrupted")
					}
					return "", nil
				}
				file, err := os.Create(temporary)
				if err != nil {
					return "", err
				}
				archive := zip.NewWriter(file)
				member := "chr.img"
				if failure == "wrong member" {
					member = "wrong.img"
				}
				entry, err := archive.Create(member)
				if err != nil {
					file.Close()
					return "", err
				}
				_, err = entry.Write([]byte("image"))
				return "", errors.Join(err, archive.Close(), file.Close())
			}
			err := Download(t.Context(), run, "https://example.test/chr.zip", path, "chr.img")
			if failure == "wrong member" {
				if err == nil || calls != 3 {
					t.Fatalf("got %v after %d calls", err, calls)
				}
				entries, err := os.ReadDir(filepath.Dir(path))
				if err != nil || len(entries) != 0 {
					t.Fatalf("cached failed download: %v, %v", entries, err)
				}
			} else {
				if err != nil || calls != 2 {
					t.Fatalf("got %v after %d calls", err, calls)
				}
				if err := Download(t.Context(), run, "https://example.test/chr.zip", path, "chr.img"); err != nil {
					t.Fatal(err)
				}
				if calls != 2 {
					t.Fatal("valid cache downloaded again")
				}
			}
		})
	}
}

func TestStoreImageRootedBeforeOverlay(t *testing.T) {
	for _, rootFailure := range []bool{false, true} {
		t.Run(fmt.Sprint(rootFailure), func(t *testing.T) {
			root := t.TempDir()
			store := filepath.Join(root, "store")
			if err := os.Mkdir(store, 0700); err != nil {
				t.Fatal(err)
			}
			if err := Write(filepath.Join(store, "chr-7.21.3.img"), "image"); err != nil {
				t.Fatal(err)
			}
			t.Setenv("CHR_IMAGE", store)
			l, err := New("7.21.3", filepath.Join(root, "state"), 2222)
			if err != nil {
				t.Fatal(err)
			}
			if err := Write(l.Path("id_ed25519"), ""); err != nil {
				t.Fatal(err)
			}
			shared := filepath.Join(root, "images")
			if err := os.Mkdir(shared, 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(shared, filepath.Join(l.Root, "images")); err != nil {
				t.Fatal(err)
			}
			calls := []string{}
			l.Run = func(_ context.Context, name string, args ...string) (string, error) {
				calls = append(calls, name)
				if name == "nix-store" {
					if !strings.Contains(strings.Join(args, " "), filepath.Join(shared, "nix-roots", filepath.Base(store))) {
						t.Fatal("GC root did not resolve shared image directory")
					}
					if rootFailure {
						return "", errors.New("root failed")
					}
				}
				return "", nil
			}
			err = l.Prepare(t.Context())
			if rootFailure {
				if err == nil || len(calls) != 1 {
					t.Fatalf("overlay created despite GC root failure: %v %v", calls, err)
				}
			} else if err != nil || strings.Join(calls, ",") != "nix-store,qemu-img" {
				t.Fatalf("unexpected order: %v %v", calls, err)
			}
		})
	}
}

func TestLockPreventsConcurrentMutation(t *testing.T) {
	root := t.TempDir()
	unlock, err := Lock(root)
	if err != nil {
		t.Fatal(err)
	}
	if second, err := Lock(root); err == nil {
		second()
		t.Fatal("concurrent lab lock succeeded")
	}
	if err := unlock(); err != nil {
		t.Fatal(err)
	}
	unlock, err = Lock(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := unlock(); err != nil {
		t.Fatal(err)
	}
}

func TestForwardRejectsUnsafePortsBeforeMonitor(t *testing.T) {
	l := &Lab{SSHPort: 2222}
	for _, tc := range []struct {
		protocol    string
		host, guest int
	}{{"invalid", 1053, 53}, {"tcp", 2222, 53}, {"udp", 53, 53}, {"tcp", 1053, 0}} {
		if _, err := l.Forward(t.Context(), tc.protocol, tc.host, tc.guest, ""); err == nil {
			t.Fatal("unsafe forward accepted")
		}
	}
}

func TestAdoptionPlanPreservesRouterConfiguration(t *testing.T) {
	for _, tc := range []struct {
		kind, name, actions string
		recovery, allowed   bool
	}{
		{"routeros_ip_address", "management", `["no-op"]`, false, true},
		{"routeros_ip_address", "management", `["update"]`, false, false},
		{"routeros_ip_address", "management", `["create"]`, false, false},
		{"routeros_ip_address", "management", `["delete"]`, false, false},
		{"routeros_ip_address", "management", `["delete","create"]`, false, false},
		{"routeros_move_items", "ipv4_filter", `["create"]`, false, true},
		{"routeros_move_items", "ipv6_filter", `["create"]`, false, true},
		{"routeros_move_items", "other", `["create"]`, false, false},
		{"routeros_move_items", "ipv4_filter", `["update"]`, false, false},
		{"routeros_move_items", "ipv4_filter", `["update"]`, true, true},
		{"routeros_move_items", "ipv6_filter", `["delete","create"]`, true, false},
		{"routeros_ip_address", "management", `["update"]`, true, false},
		{"local_file", "script", `["create"]`, false, true},
		{"routeros_file", "script", `["create"]`, false, true},
		{"routeros_file", "script", `["update"]`, false, false},
		{"routeros_file", "other", `["create"]`, false, false},
	} {
		t.Run(tc.kind+tc.name+tc.actions+fmt.Sprint(tc.recovery), func(t *testing.T) {
			plan := fmt.Sprintf(`{"resource_changes":[{"address":"resource.test","type":%q,"name":%q,"change":{"actions":%s}}]}`, tc.kind, tc.name, tc.actions)
			err := VerifyAdoptionPlan(t.Context(), plan, tc.recovery)
			if (err == nil) != tc.allowed {
				t.Fatalf("allowed=%t: %v", tc.allowed, err)
			}
		})
	}
}

func TestGeneratedFirewallTableOrder(t *testing.T) {
	for _, site := range []string{"stationary", "kuberack"} {
		data, err := os.ReadFile(filepath.Join("../../../../local-networking/bootstrap/generated", site+".rsc"))
		if err != nil {
			t.Fatal(err)
		}
		tables := []string{}
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "/ip/firewall/") || strings.HasPrefix(line, "/ipv6/firewall/") {
				table, _, _ := strings.Cut(line, " add ")
				if len(tables) == 0 || tables[len(tables)-1] != table {
					tables = append(tables, table)
				}
			}
		}
		if strings.Join(tables, ",") != "/ip/firewall/nat,/ip/firewall/filter,/ipv6/firewall/address-list,/ipv6/firewall/filter" {
			t.Fatalf("%s: wrong table order: %v", site, tables)
		}
	}
}

func TestQemuAllocatesDistinctBoundPorts(t *testing.T) {
	// Go's test-name directory can exceed the Unix socket limit under Nix's TMPDIR.
	root, err := os.MkdirTemp("", "chr-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(root); err != nil {
			t.Error(err)
		}
	})
	routers := []*BootstrapLab{}
	ports := map[int]bool{}
	for i, name := range []string{"stationary", "kuberack"} {
		router, err := NewBootstrap("7.21.3", root, filepath.Join(root, "run"), name, "", filepath.Join(root, "transit.sock"), i == 0)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := Command(t.Context(), "qemu-img", "create", "-f", "qcow2", router.Path("disk.qcow2"), "1M"); err != nil {
			t.Fatal(err)
		}
		args := []string{"-S", "-nodefaults", "-m", "64", "-display", "none", "-monitor", "unix:" + router.Path("monitor.sock") + ",server=on,wait=off", "-pidfile", router.Path("qemu.pid"), "-drive", "file=" + router.Path("disk.qcow2") + ",format=qcow2,if=virtio"}
		args = append(args, router.networkArgs(router.Path("capture.pcap"))...)
		cmd := exec.Command("qemu-system-x86_64", args...)
		stderr, err := os.Create(filepath.Join(root, name+".log"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if err := stderr.Close(); err != nil {
				t.Error(err)
			}
		})
		cmd.Stderr = stderr
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if cmd.Process != nil {
				_ = cmd.Process.Kill()
				_ = cmd.Wait()
			}
		})
		ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
		defer cancel()
		for {
			if _, err := os.Stat(router.Path("monitor.sock")); err == nil {
				break
			}
			if err := Sleep(ctx, 10*time.Millisecond); err != nil {
				output, readErr := os.ReadFile(stderr.Name())
				if readErr != nil {
					t.Fatal(readErr)
				}
				t.Fatalf("QEMU did not start: %s", output)
			}
		}
		if err := router.NetworkReady(ctx); err != nil {
			t.Fatal(err)
		}
		for _, port := range []int{router.SSHPort, router.HTTPSPort} {
			if port == 0 || ports[port] {
				t.Fatalf("reused port %d", port)
			}
			ports[port] = true
			listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
			if err == nil {
				listener.Close()
				t.Fatalf("QEMU did not bind port %d", port)
			}
		}
		routers = append(routers, router)
	}
	router := routers[0]
	if _, err := router.Monitor(t.Context(), fmt.Sprintf("hostfwd_remove lab tcp:127.0.0.1:%d", router.SSHPort)); err != nil {
		t.Fatal(err)
	}
	if _, err := router.Monitor(t.Context(), "hostfwd_add lab tcp:127.0.0.1:0-"+router.Address+":22"); err != nil {
		t.Fatal(err)
	}
	if err := router.NetworkReady(t.Context()); err != nil {
		t.Fatal(err)
	}
	if router.SSHPort == routers[1].SSHPort || router.SSHPort == routers[1].HTTPSPort {
		t.Fatal("rebound port overlaps another router")
	}
	remove, err := router.Forward(t.Context(), "udp", 0, 53, router.Address)
	if err != nil {
		t.Fatal(err)
	}
	port, err := router.ForwardedPort(t.Context(), "udp", 53)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
	if err == nil {
		listener.Close()
		t.Fatal("QEMU did not bind UDP forward")
	}
	if err := remove(); err != nil {
		t.Fatal(err)
	}
}
