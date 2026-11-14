# A klusse runner VM formats its blank claim on first boot and keeps /home on it, reads its Amp
# key from the Secret disk, and starts the runner only after the isolation check reaches the
# internet and nothing private. Its own firewall rejects private destinations except for the
# check, so the check tests the cluster's policy. Here `internet` stands in for the internet
# and `lan` for a private host, which the cluster's policy hides until the test opens it.
{ pkgs }:
let
  # Stands in for the Amp CLI: records how it was started, then stays up like a runner.
  fakeAmp = pkgs.writeShellScriptBin "amp" ''
    mkdir -p "$HOME/probe"
    printf '%s\n' "$@" > "$HOME/probe/args"
    printf '%s' "$AMP_API_KEY" > "$HOME/probe/key"
    exec sleep infinity
  '';
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
    import subprocess
    import time
    from pathlib import Path

    disk = Path.cwd() / "klusse-runner-claim.qcow2"
    subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-q", "-f", "qcow2", str(disk), "4G"], check=True)
    os.environ["KLUSSE_RUNNER_DISK"] = str(disk)

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
