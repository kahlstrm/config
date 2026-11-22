# A klusse runner VM formats its blank claim on first boot and keeps /home on it, reads its Amp
# key from the Secret disk, and starts the runner only after the isolation check reaches the
# internet and nothing private. Its own firewall rejects private destinations except for the
# check and the targets it lists, so the check tests the cluster's policy. Here `internet`
# stands in for the internet and `lan` for a private host, which the cluster's policy hides
# until the test opens it.
#
# With orbs, the VM creates its orb provider once with the runner's key and runs it without
# that key, and a second one for the workspace. The dispatch program starts an orb as a container, keeps its files across a pause,
# saves and starts from project snapshots, caps an orb's files and removes it on delete; the
# guest firewall covers orbs too. A pause records the orb's git facts, and cleanup, which
# starts in a dry run, drops stopped orbs whose work is on a remote: archived for a day,
# stopped for 7 days, or early when the disk is over 80 % full. It checks orbs stopped
# without facts from a copy, keeps unsafe ones and reports them over 90 %, and removes
# snapshots no orb uses. `fakeApi` stands in for Amp's thread metadata.
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
  # Amp's thread metadata: only T-five is archived.
  fakeApi = pkgs.writeText "fake-amp-api.py" ''
    import http.server
    import json

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            with open("/run/amp-api-authorization", "w") as f:
                f.write(self.headers.get("Authorization", ""))
            if self.path == "/api/v2/threads/T-five/metadata":
                self.send_response(200)
                body = {"id": "T-five", "archived": True, "updatedAt": "2000-01-01T00:00:00Z"}
            else:
                self.send_response(404)
                body = {"error": "not found"}
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(body).encode())

    http.server.HTTPServer(("127.0.0.1", 8081), Handler).serve_forever()
  '';
  # Stands in for Amp's orb image: its amp records the token `amp orb bootstrap` got, and it
  # has git, which the pause's check runs.
  orbImage = pkgs.dockerTools.buildImage {
    name = "orb-test";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "orb-test-root";
      paths = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.findutils
        pkgs.gitMinimal
        (pkgs.writeShellScriptBin "amp" ''
          printf '%s %s' "$*" "$ORB_TOKEN" > /bootstrapped
          echo "bootstrap says $ORB_TOKEN" >&2
        '')
      ];
      pathsToLink = [ "/bin" ];
    };
    extraCommands = "mkdir -m 1777 tmp; mkdir -p home/user";
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
    { lib, nodes, ... }:
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
        allowedPrivate = [ "${nodes.lan.networking.primaryIPAddress}:8080" ];
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
      systemd.services.fake-amp-api = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${fakeApi}";
      };
      systemd.services.amp-orb-cleanup.environment.AMP_URL = lib.mkForce "http://127.0.0.1:8081";
      # Stands in for the Git host orbs push to: cleanup confirms their commits there.
      systemd.services.git-daemon = {
        wantedBy = [ "multi-user.target" ];
        preStart = "mkdir -p /srv/git";
        serviceConfig.ExecStart = "${pkgs.git}/bin/git daemon --export-all --reuseaddr --listen=127.0.0.1 --base-path=/srv/git";
      };
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
    import json
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
        # The next spawn reports what the last bootstrap said.
        runner.wait_until_succeeds("journalctl --output cat --unit amp-orb-log | grep -qx 'amp-one: bootstrap says first'")
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

    with subtest("Deleting an orb removes it"):
        dispatch("delete", "amp-three")
        dispatch("delete", "amp-three")
        runner.fail("docker container inspect amp-three")

    git = "git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main"
    push = f"{git} push --quiet origin main"

    def checkout(orb, *steps):
        script = " && ".join([
            f"{git} init --quiet --bare /srv/origin.git",
            f"{git} clone --quiet /srv/origin.git /home/user/workspace/repo",
            "cd /home/user/workspace/repo",
            "echo one > tracked",
            f"{git} add tracked",
            f"{git} commit --quiet -m one",
            *steps,
            # A remote in the orb goes with it, so the Git host serves a copy of it.
            f"{git} remote set-url origin git://127.0.0.1/{orb}.git",
        ])
        runner.succeed(f"docker exec {orb} sh -c '{script}'")
        runner.succeed(f"docker cp {orb}:/srv/origin.git /srv/git/{orb}.git")

    def facts(orb):
        return json.loads(runner.succeed(f"cat /var/lib/amp-orb-facts/{orb}.json"))

    def cleanup(succeeds=True):
        (runner.succeed if succeeds else runner.fail)("systemctl start amp-orb-cleanup.service")
        return runner.succeed("journalctl --output cat --unit amp-orb-cleanup").split("checking ")[-1]

    def exists(*orbs):
        for orb in orbs:
            runner.succeed(f"docker container inspect {orb}")

    def gone(*orbs):
        for orb in orbs:
            runner.fail(f"docker container inspect {orb}")
            runner.fail(f"test -e /var/lib/amp-orb-facts/{orb}.json")

    with subtest("A pause records what only the orb holds"):
        # The test runs cleanup itself, at the times it sets.
        runner.succeed("systemctl stop amp-orb-cleanup.timer")
        orbs = ["amp-four", "amp-five", "amp-six", "amp-seven", "amp-eight"]
        for orb in orbs:
            dispatch("spawn", orb, ORB_IMAGE="orb-test:latest", ORB_TOKEN=orb)
        checkout("amp-four")
        for orb in ("amp-five", "amp-six", "amp-seven"):
            checkout(orb, push)
        checkout("amp-eight", push, "echo two > tracked")
        for orb in ("amp-two", "amp-four", "amp-five", "amp-six"):
            dispatch("pause", orb)
        # Stopped without a pause, as a VM restart stops them.
        runner.succeed("docker stop amp-seven amp-eight")
        four = facts("amp-four")
        assert four["source"] == "pause", four
        [repo] = four["repos"]
        assert repo["path"] == "/home/user/workspace/repo" and repo["branch"] == "main", repo
        assert repo["unpushed"] == 1 and len(repo["head"]) == 40, repo
        [repo] = facts("amp-five")["repos"]
        assert repo["unpushed"] == 0 and repo["changed"] == 0 and repo["untracked"] == 0, repo
        assert facts("amp-two")["repos"] == []
        runner.fail("test -e /var/lib/amp-orb-facts/amp-seven.json")

    with subtest("Cleanup starts in a dry run, which only logs its decisions"):
        runner.succeed("date -s '+2 days'")
        log = cleanup()
        assert "dry run" in log, log
        assert "would drop amp-five: safe, archived, stopped 2 days" in log, log
        assert "keep amp-six: safe, stopped 2 days" in log, log
        assert "keep amp-four: stopped 2 days, unsafe: /home/user/workspace/repo: 1 commits on no remote" in log, log
        assert runner.succeed("cat /run/amp-api-authorization") == "Bearer sgamp_klusse_test"
        exists("amp-two", *orbs)
        # Orbs stopped without facts are checked from a copy, which is kept.
        assert facts("amp-seven")["source"] == "copy"
        assert "keep amp-seven: safe, stopped 2 days" in log, log
        assert "keep amp-eight: stopped 2 days, unsafe: /home/user/workspace/repo: 1 changed files" in log, log

    with subtest("A safe orb whose thread is archived goes after a day"):
        runner.succeed("touch /var/lib/amp-orb-cleanup/enforce")
        log = cleanup()
        assert "dropped amp-five: safe, archived" in log, log
        gone("amp-five")
        exists("amp-two", "amp-four", "amp-six", "amp-seven", "amp-eight")

    with subtest("Safe orbs stopped for 7 days go, and snapshots no orb uses"):
        runner.succeed("date -s '+6 days'")
        log = cleanup()
        for orb in ("amp-two", "amp-six", "amp-seven"):
            assert f"dropped {orb}: safe, stopped 8 days" in log, log
        gone("amp-two", "amp-six", "amp-seven")
        exists("amp-four", "amp-eight")
        assert state("amp-one") == "running"
        assert "removed image snapshot-one:latest" in log, log
        runner.fail("docker image inspect snapshot-one")
        runner.succeed("docker image inspect orb-test:latest")

    with subtest("Over 80 % full, safe orbs go early; over 90 %, unsafe ones are kept and reported"):
        dispatch("spawn", "amp-nine", ORB_IMAGE="orb-test:latest", ORB_TOKEN="nine")
        dispatch("pause", "amp-nine")
        # Only orbs stopped for an hour, so a pause has finished saving its snapshot.
        runner.succeed("date -s '+2 hours'")
        runner.succeed("fallocate -l $(( $(df --output=size -B1 /var/lib/docker | tail -1) * 92 / 100 - $(df --output=used -B1 /var/lib/docker | tail -1) )) /var/lib/docker/fill")
        log = cleanup(succeeds=False)
        assert "dropped amp-nine: safe, disk 9" in log, log
        gone("amp-nine")
        exists("amp-four", "amp-eight")
        assert re.search(r"^ALERT: orb disk 9\d % used; .*: amp-four amp-eight$", log, re.M), log
        runner.succeed("rm /var/lib/docker/fill")

    with subtest("Unsafe orbs stay past 30 days, and running ones are never touched"):
        runner.succeed("date -s '+25 days'")
        log = cleanup()
        assert "keep amp-four: stopped 33 days, kept until unpushed work can be rescued" in log, log
        exists("amp-four", "amp-eight")
        assert state("amp-one") == "running"

    with subtest("The guest firewall allows the private targets it lists"):
        lan.succeed("iptables -I nixos-fw -p tcp --dport 8080 -j nixos-fw-accept")
        runner.succeed("su -s /bin/sh amp -c 'timeout 5 bash -c \"exec 3<>/dev/tcp/lan/8080\"'")
        lan.succeed("iptables -D nixos-fw -p tcp --dport 8080 -j nixos-fw-accept")

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
