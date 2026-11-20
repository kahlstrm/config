# A klusse runner VM formats its blank claim on first boot and keeps /home on it, reads its Amp
# key from the Secret disk, and starts the runner only after the isolation check reaches the
# internet and nothing private. Its own firewall rejects private destinations except for the
# check, so the check tests the cluster's policy. Here `internet` stands in for the internet
# and `lan` for a private host, which the cluster's policy hides until the test opens it.
#
# With orbs, the VM creates its orb provider once with the runner's key and runs it without
# that key, and a second one for the workspace. The dispatch program starts an orb as a container, keeps its files across a pause,
# saves and starts from project snapshots, caps an orb's files and removes it on delete; the
# guest firewall covers orbs too, and orbs stopped for long are removed.
{ pkgs }:
let
  # Stands in for the Amp CLI: records how it was started, then stays up like a runner or an
  # orb provider. Creating a provider and making it the default return at once.
  fakeAmp = pkgs.writeShellScriptBin "amp" ''
    mkdir -p "$HOME/probe"
    printf '%s\n' "$@" > "$HOME/probe/args"
    printf '%s' "$AMP_API_KEY" > "$HOME/probe/key"
    printf '%s key=%s image=%s\n' "$*" "$AMP_API_KEY" "$ORB_IMAGE" >> "$HOME/probe/calls"
    case "$*" in
      "orb provider create "* | "orb provider set-default "*) exit 0 ;;
    esac
    exec sleep infinity
  '';
  # Stands in for Amp's orb image: its amp records the token `amp orb bootstrap` got.
  orbImage = pkgs.dockerTools.buildImage {
    name = "orb-test";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "orb-test-root";
      paths = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        (pkgs.writeShellScriptBin "amp" ''
          printf '%s %s' "$*" "$ORB_TOKEN" > /bootstrapped
        '')
      ];
      pathsToLink = [ "/bin" ];
    };
    config.Env = [ "PATH=/bin" ];
  };
  # KubeVirt presents the Secret's keys as files on an ISO 9660 disk.
  tokenDisk = pkgs.runCommand "amp-runner-token.iso" { nativeBuildInputs = [ pkgs.cdrkit ]; } ''
    mkdir secret
    printf %s sgamp_klusse_test > secret/key
    genisoimage -quiet -output $out -volid cfgdata -joliet -rock secret
  '';
in
pkgs.testers.runNixOSTest {
  name = "klusse-runner";
  nodes.runner =
    { lib, ... }:
    {
      imports = [
        ../modules/amp-runner.nix
        ../modules/klusse-runner
      ];
      local.ampRunner = {
        package = fakeAmp;
        repositories = lib.mkForce [ ];
      };
      local.klusseRunner = {
        mustReach = [ "internet:443" ];
        mustNotReach = [
          "lan:8080"
          "lan:1053/udp"
        ];
        orbs = {
          enable = true;
          workspace = true;
          image = "orb-test:latest";
          cpus = 1;
          memory = "512m";
          diskLimit = "64M";
        };
      };
      # The test's own network replaces KubeVirt's DHCP.
      systemd.network.networks."10-pod".enable = false;
      virtualisation = {
        memorySize = 2048;
        mountHostNixStore = false;
        useNixStoreImage = true;
        writableStore = false;
        useDefaultFilesystems = false;
        fileSystems = lib.mkForce { };
        diskImage = null;
        qemu.options = [
          "-drive file=$KLUSSE_RUNNER_DISK,if=none,id=persistent,format=qcow2"
          "-device virtio-blk-pci,drive=persistent,serial=persistent"
          "-drive file=${tokenDisk},if=none,id=token,format=raw,readonly=on"
          "-device virtio-blk-pci,drive=token,serial=amp-runner-token"
          "-drive file=$KLUSSE_ORBS_DISK,if=none,id=orbs,format=qcow2"
          "-device virtio-blk-pci,drive=orbs,serial=orbs"
        ];
      };
    };
  nodes.internet = {
    networking.firewall.allowedTCPPorts = [ 443 ];
    systemd.services.listener = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:443,fork,reuseaddr SYSTEM:true";
    };
  };
  # Listens on TCP 8080 and answers on UDP 1053 behind a firewall that drops both, as the
  # cluster's policy does.
  nodes.lan = {
    networking.firewall.rejectPackets = false;
    systemd.services.listener = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:8080,fork,reuseaddr SYSTEM:true";
    };
    systemd.services.udp-listener = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.socat}/bin/socat UDP-LISTEN:1053,fork,reuseaddr SYSTEM:date";
    };
  };
  testScript = ''
    import os
    import re
    import subprocess
    import time
    from pathlib import Path

    disk = Path.cwd() / "klusse-runner-claim.qcow2"
    subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-q", "-f", "qcow2", str(disk), "4G"], check=True)
    os.environ["KLUSSE_RUNNER_DISK"] = str(disk)
    orbs_disk = Path.cwd() / "klusse-runner-orbs.qcow2"
    subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-q", "-f", "qcow2", str(orbs_disk), "4G"], check=True)
    os.environ["KLUSSE_ORBS_DISK"] = str(orbs_disk)

    internet.wait_for_unit("listener.service")
    lan.wait_for_unit("listener.service")
    lan.wait_for_open_port(8080)
    lan.wait_for_unit("udp-listener.service")

    with subtest("The blank claim is formatted and holds /nix, /home, /var and /tmp"):
        runner.wait_for_unit("multi-user.target")
        assert runner.succeed("findmnt -n -o FSTYPE /nix").strip() == "ext4"
        for path in ("/home", "/var", "/tmp"):
            source = runner.succeed(f"findmnt -n -o SOURCE {path}").strip()
            assert source.endswith(f"[/persist{path}]"), (path, source)

    with subtest("The runner starts after the check, with the key from the Secret disk"):
        runner.wait_for_unit("amp-runner.service")
        runner.wait_until_succeeds("test -e /home/amp/probe/key")
        assert runner.succeed("cat /home/amp/probe/key") == "sgamp_klusse_test"
        args = runner.succeed("cat /home/amp/probe/args").split()
        assert args[args.index("--runner-id") + 1] == "runner", args
        assert args[args.index("--discover-dirs") + 1] == "/home/amp/workspace", args
        runner.succeed("su -s /bin/sh amp -c 'sudo -n true'")
        runner.succeed("su -s /bin/sh amp -c 'touch /home/amp/kept'")

    def calls():
        return runner.succeed("cat /var/lib/amp-orbs/probe/calls").splitlines()

    def dispatch(operation, orb, **job):
        variables = " ".join(f"{name}={value}" for name, value in job.items())
        runner.succeed(f"su -s /bin/sh amp-orbs -c 'ORB_OPERATION={operation} ORB_ID={orb} {variables} {program}'")

    def state(orb):
        return runner.succeed(f"docker inspect --format '{{{{.State.Status}}}}' {orb}").strip()

    with subtest("Docker keeps orbs on their own disk"):
        runner.wait_for_unit("docker.service")
        assert runner.succeed("findmnt -n -o FSTYPE /var/lib/docker").strip() == "xfs"
        # The provider waits for the image, which it cannot pull here.
        runner.succeed("docker load --input ${orbImage}")

    with subtest("The provider is created once with the runner's key and runs without it"):
        runner.wait_for_unit("amp-orb-provider.service")
        runner.wait_until_succeeds("test $(wc -l < /var/lib/amp-orbs/probe/calls) -eq 3")
        created, default, running = calls()
        assert created == "orb provider create runner key=sgamp_klusse_test image=orb-test:latest", created
        assert default == "orb provider set-default runner key=sgamp_klusse_test image=orb-test:latest", default
        program = running.split()[2]
        assert running == f"orb provider {program} key= image=orb-test:latest", running
        runner.succeed("systemctl restart amp-orb-provider.service")
        runner.wait_until_succeeds("test $(wc -l < /var/lib/amp-orbs/probe/calls) -eq 4")
        assert calls()[3] == running, calls()

    with subtest("The workspace's provider is created beside it, with its own state"):
        runner.wait_for_unit("amp-orb-provider-workspace.service")
        runner.wait_until_succeeds("test $(wc -l < /var/lib/amp-orbs-workspace/probe/calls) -eq 3")
        created, default, running = runner.succeed("cat /var/lib/amp-orbs-workspace/probe/calls").splitlines()
        assert created == "orb provider create runner-workspace --workspace key=sgamp_klusse_test image=orb-test:latest", created
        assert default == "orb provider set-default runner-workspace --workspace key=sgamp_klusse_test image=orb-test:latest", default
        assert running == f"orb provider {program} key= image=orb-test:latest", running

    with subtest("An orb starts with its token and keeps its files across a pause"):
        dispatch("spawn", "amp-one", ORB_IMAGE="orb-test:latest", ORB_TOKEN="first")
        runner.wait_until_succeeds("docker exec amp-one test -e /bootstrapped")
        assert runner.succeed("docker exec amp-one cat /bootstrapped") == "orb bootstrap first"
        runner.succeed("docker exec amp-one touch /kept")
        dispatch("spawn", "amp-one", ORB_IMAGE="orb-test:latest", ORB_TOKEN="first")
        dispatch("pause", "amp-one", ORB_SNAPSHOT_ID="snapshot-one")
        assert state("amp-one") == "exited"
        dispatch("pause", "amp-one")
        dispatch("spawn", "amp-one", ORB_IMAGE="orb-test:latest", ORB_TOKEN="second")
        runner.wait_until_succeeds("docker exec amp-one grep -q second /bootstrapped")
        runner.succeed("docker exec amp-one test -e /kept")

    with subtest("A new orb starts from a project snapshot saved here"):
        dispatch("spawn", "amp-two", ORB_IMAGE="orb-test:latest", ORB_SNAPSHOT_ID="snapshot-one", ORB_TOKEN="third")
        runner.succeed("docker exec amp-two test -e /kept")
        dispatch("spawn", "amp-three", ORB_IMAGE="orb-test:latest", ORB_SNAPSHOT_ID="snapshot-none", ORB_TOKEN="fourth")
        runner.fail("docker exec amp-three test -e /kept")

    with subtest("An orb cannot add more files than its limit"):
        runner.succeed("docker exec amp-one dd if=/dev/zero of=/small bs=1M count=16")
        runner.fail("docker exec amp-one dd if=/dev/zero of=/large bs=1M count=128")

    with subtest("The guest firewall rejects private destinations from an orb"):
        address = internet.succeed("ip -4 -o addr show eth1").split()[3].split("/")[0]
        connect = f"docker exec amp-one timeout 5 bash -c 'exec 3<>/dev/tcp/{address}/443'"
        # Allowed for a moment, to show the orb's network works and only the firewall stops it.
        rule = runner.succeed(f"nft --echo --handle insert rule inet runner-egress forward ip daddr {address} accept")
        runner.succeed(connect)
        runner.succeed(f"nft delete rule inet runner-egress forward handle {re.findall(r"# handle (\d+)", rule)[0]}")
        runner.fail(connect)

    with subtest("Deleting an orb removes it, and orbs stopped for long are removed"):
        dispatch("delete", "amp-three")
        dispatch("delete", "amp-three")
        runner.fail("docker container inspect amp-three")
        dispatch("pause", "amp-two")
        runner.succeed("date -s '+40 days'")
        runner.succeed("systemctl start amp-orb-reap.service")
        runner.fail("docker container inspect amp-two")
        assert state("amp-one") == "running"

    with subtest("The guest firewall rejects private destinations, except for the check"):
        runner.fail("su -s /bin/sh amp -c 'timeout 5 bash -c \"exec 3<>/dev/tcp/internet/443\"'")
        runner.fail("timeout 5 bash -c 'exec 3<>/dev/tcp/internet/443'")
        runner.succeed("setpriv --reuid=isolation-check --regid=isolation-check --clear-groups timeout 5 bash -c 'exec 3<>/dev/tcp/internet/443'")

    with subtest("A private UDP service it reaches keeps the runner down"):
        lan.succeed("iptables -I nixos-fw -p udp --dport 1053 -j nixos-fw-accept")
        runner.fail("systemctl restart runner-isolation-check.service")
        runner.fail("systemctl is-active amp-runner.service")
        assert "lan:1053/udp open, expected timeout" in runner.succeed("journalctl -u runner-isolation-check --no-pager")
        lan.succeed("iptables -D nixos-fw -p udp --dport 1053 -j nixos-fw-accept")

    with subtest("A private target it reaches keeps the runner down, also when TCP works late and after a reboot"):
        lan.succeed("iptables -I nixos-fw -p tcp --dport 8080 -j nixos-fw-accept")
        # TCP is dropped for the check's first probes, so a private probe run then would time out.
        runner.succeed("nft add table inet late")
        runner.succeed("nft add chain inet late output '{ type filter hook output priority -10; }'")
        runner.succeed("nft add rule inet late output meta l4proto tcp drop")
        runner.succeed("systemctl start --no-block runner-isolation-check.service")
        time.sleep(7)
        runner.succeed("nft delete table inet late")
        runner.wait_until_succeeds("systemctl is-failed runner-isolation-check.service", timeout=120)
        runner.fail("systemctl is-active amp-runner.service")
        assert "lan:8080 open, expected timeout" in runner.succeed("journalctl -u runner-isolation-check --no-pager")
        runner.shutdown()
        runner.start()
        runner.wait_for_unit("multi-user.target")
        runner.wait_until_succeeds("systemctl is-failed runner-isolation-check.service")
        runner.fail("systemctl is-active amp-runner.service")
        runner.succeed("test -e /home/amp/kept")
  '';
}
