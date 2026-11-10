# An Amp runner on a host runs as the unprivileged amp user. From inside its service it may
# queue agent-deploy of merged upstream main and read its status and log, without approval,
# and start, stop, restart and reload units other than the protected ones, but cannot gain
# privileges or read the host's secrets. It snapshots service state before a migration, and
# expiring or pruning those snapshots deletes no other subvolume. Its token
# reaches the runner only through the service's credentials, and ops' deploy path keeps
# working beside it while both exist. The token here is installed by hand, encrypted with
# systemd-creds into the credential store, as on the hosts. A runner in a VM without
# host-deploy, as on ops, gets its token from the VM's host as a system credential, decides
# every permission through its own rules, and stays skipped while that credential is empty.
{ pkgs }:
let
  # Stands in for the Amp CLI: like the real one it refuses to start without a key or a saved
  # login; otherwise it records how it was started, probes what a thread on the runner could
  # do from inside the service, and stays up like a runner.
  fakeAmp = pkgs.writeShellApplication {
    name = "amp";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      if [ -z "''${AMP_API_KEY:-}" ] && [ ! -e "$HOME/.local/share/amp/secrets.json" ]; then
        echo 'Error: API key required for --no-tui. Please run amp login first.' >&2
        exit 1
      fi
      out="$HOME/probe"
      mkdir -p "$out"
      printf '%s\n' "$@" > "$out/args"
      printf '%s' "''${AMP_API_KEY:-}" > "$out/key"
      id -un > "$out/user"
      probe() {
        name=$1
        shift
        if "$@" > "$out/$name.out" 2>&1; then echo ok > "$out/$name"; else echo denied > "$out/$name"; fi
      }
      probe status host-deploy status
      probe deploy host-deploy deploy
      probe restart-sshd systemctl --no-ask-password restart sshd.service
      probe stop-deploy systemctl --no-ask-password stop agent-deploy.service
      probe restart-other systemctl --no-ask-password restart other-logger.service
      probe restart-protected systemctl --no-ask-password restart other-protected.service
      probe kill-other systemctl --no-ask-password kill other-logger.service
      probe transient systemd-run --no-ask-password touch /run/transient-ran
      probe transient-named systemd-run --no-ask-password --unit=other-logger touch /run/transient-ran
      probe stop-sysinit systemctl --no-ask-password stop sysinit.target
      probe isolate systemctl --no-ask-password isolate multi-user.target
      probe stop-slice systemctl --no-ask-password stop system.slice
      probe sudo /run/wrappers/bin/sudo -n true
      probe host-key cat /etc/ssh/ssh_host_ed25519_key
      probe token-file cat /etc/credstore.encrypted/amp-runner.token
      probe write-etc touch /etc/injected
      probe system-tools command -v lsblk
      probe nix-daemon nix --extra-experimental-features nix-command store info
      # Threads' login shells find kubectl and flux with the break-glass kubeconfig.
      probe kubeconfig bash -lc "kubectl config view --minify --output=jsonpath={.users[0].user.tokenFile}"
      probe kube-token cat /run/kube-token
      probe flux bash -lc "flux version --client"
      echo finished > "$out/finished"
      exec sleep infinity
    '';
  };
  vmRunner = credential: {
    imports = [ ../modules/amp-runner.nix ];
    system.stateVersion = "26.05";
    virtualisation.qemu.options = [ credential ];
    local.ampRunner = {
      enable = true;
      hostDeploy = false;
      runnerId = "guest";
      package = fakeAmp;
      extraPermissions = [
        {
          tool = "*";
          action = "ask";
        }
      ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "agent-amp-runner";
  nodes.host =
    { lib, pkgs, ... }:
    {
      imports = [
        ../modules/amp-runner.nix
        ../modules/ops-deploy.nix
        ../modules/state-snapshot.nix
      ];
      system.stateVersion = "26.05";
      virtualisation.emptyDiskImages = [ 512 ];
      boot.supportedFilesystems = [ "btrfs" ];
      local.stateSnapshot = {
        enable = true;
        name = "app";
        directory = "/mnt/data/.snapshots";
        subvolumes = [ "/mnt/data/state/app" ];
        services = [ "app.service" ];
      };
      systemd.services.app.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      systemd.services.other-protected = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "other-dependency.service" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
      # Stopping it would stop other-protected, so it is protected with it.
      systemd.services.other-dependency = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      };
      # Like the hosts, the daemon serves only listed users.
      nix.settings.allowed-users = [ "root" ];
      services.openssh.enable = true;
      local.opsDeploy = {
        enable = true;
        configuration = "host";
        authorizedKeys = [ ];
      };
      local.ampRunner = {
        enable = true;
        configuration = "host";
        runnerId = "host";
        package = fakeAmp;
        kubernetesTokenFile = "/run/kube-token";
        protectedUnits = [ "other-protected.service" ];
        readOnlyUnits = [ "other-logger.service" ];
      };
      # Stands in for the agenix secret on the hosts.
      systemd.tmpfiles.rules = [ "f /run/kube-token 0400 amp amp - test-kube-token" ];
      users.users.other = {
        isNormalUser = true;
      };
      # A service amp did not start, whose journal amp reads when debugging the host.
      systemd.services.other-logger = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Type = "oneshot";
        script = "echo other-entry";
      };
      # The runner itself is covered by the agent-deploy test; this records that it ran.
      local.agentEnvironment.deploy.package = lib.mkForce (
        pkgs.writeShellScriptBin "agent-deploy-runner" ''
          mkdir -p /nix/var/nix/profiles/agent-deploy
          echo '{"state": "succeeded"}' > /nix/var/nix/profiles/agent-deploy/status.json
          echo "deployed $1"
          touch /run/deployed
        ''
      );
    };
  nodes.guest = vmRunner "-fw_cfg name=opt/io.systemd.credentials/amp-runner.token,string=sgamp_vm_token";
  # The host passes an empty file until a maintainer installs the key.
  nodes.pending = vmRunner "-fw_cfg name=opt/io.systemd.credentials/amp-runner.token,file=/dev/null";
  testScript = ''
    import json
    import re

    host.wait_for_unit("multi-user.target")
    probe = "/var/lib/amp-runner/probe"

    # Without a key or a saved login the runner is skipped, not failed, so a deployment that
    # adds it switches cleanly before the key is installed.
    assert host.succeed("systemctl show amp-runner.service -p ConditionResult --value").strip() == "no"
    assert host.succeed("systemctl list-units --failed --no-legend --plain").strip() == "", host.succeed("systemctl --failed")
    host.fail(f"test -e {probe}")

    # A login saved by `amp login` as amp is enough to start it.
    host.succeed("install -d -o amp -g amp /var/lib/amp-runner/.local/share/amp && touch /var/lib/amp-runner/.local/share/amp/secrets.json")
    host.succeed("systemctl restart amp-runner.service")
    host.wait_until_succeeds(f"test -e {probe}/finished")
    assert host.succeed(f"cat {probe}/key") == "", host.succeed(f"cat {probe}/key")
    host.succeed("rm /var/lib/amp-runner/.local/share/amp/secrets.json")

    # The key is installed by hand, encrypted for this host, and the runner picks it up by name.
    host.succeed(
        "install -d -m 0700 /etc/credstore.encrypted && printf %s sgamp_test_token"
        " | systemd-creds encrypt --name=amp-runner.token - /etc/credstore.encrypted/amp-runner.token"
    )
    host.fail("grep -q sgamp_test_token /etc/credstore.encrypted/amp-runner.token")
    # Start from no deployment again: the login run already queued one.
    host.wait_until_fails("systemctl is-active agent-deploy.service")
    host.succeed("rm -f /run/deployed /nix/var/nix/profiles/agent-deploy/status.json")
    host.succeed(f"rm -r {probe} && systemctl restart amp-runner.service")
    host.wait_until_succeeds(f"test -e {probe}/finished")

    def result(name):
        return host.succeed(f"cat {probe}/{name}").strip()

    def as_amp(command):
        return f"su -s /bin/sh amp -c 'systemctl --no-ask-password {command}'"

    # The runner runs as amp with a stable runner ID and Nix-managed settings.
    assert result("user") == "amp", result("user")
    args = host.succeed(f"cat {probe}/args").split()
    assert args[:3] == ["--no-tui", "--runner-id", "host"], args
    settings = json.loads(host.succeed(f"cat {args[args.index('--settings-file') + 1]}"))
    rules = settings["amp.permissions"]
    shells = {"Bash", "shell_command", "async_shell_command"}
    # host-deploy, single read-only kubectl and flux commands, and reading units and journals are
    # allowed without approval in every shell tool; managing units asks; and kubectl and flux
    # with chaining, pipes or redirects are rejected.
    # Nothing else is decided here, so other commands fall through to Amp's built-in rules.
    for tool in shells:
        assert any(r["tool"] == tool and r["action"] == "allow" and "host-deploy" in json.dumps(r.get("matches")) for r in rules), rules
    assert {r["tool"] for r in rules} == shells, rules

    def decide(tool, command):
        for r in rules:
            if r["tool"] != tool:
                continue
            for pattern in next(iter(r["matches"].values())):
                if re.search(pattern[1:-1], command) if pattern.startswith("/") else pattern == command:
                    return r["action"]
        return "built-in"

    for tool in shells:
        for command in (
            "host-deploy status",
            "flux get kustomizations",
            "kubectl -n amp-runner get externalsecret,deploy,pods",
            "kubectl -n amp-runner describe pod -l app=amp-runner",
            "kubectl -n amp-runner logs deploy/amp-runner --tail=100",
            "kubectl get pods -A -o jsonpath='{.items[*].metadata.name}'",
            "flux logs --all-namespaces --level=error",
            "systemctl status jellyfin.service seerr",
            "systemctl show -p ActiveState jellyfin",
            "systemctl list-units --failed",
            "journalctl -u jellyfin --since -1h --no-pager",
            "journalctl -u 'seerr' -n 200",
            "systemctl start other-logger.service",
        ):
            assert decide(tool, command) == "allow", (tool, command)
        for command in (
            "systemctl restart jellyfin",
            "systemctl stop jellyfin.service seerr.service",
            "systemctl start state-snapshot.service",
            "systemctl start reboot.target",
            "systemctl reload nginx",
        ):
            assert decide(tool, command) == "ask", (tool, command)
        for command in (
            "kubectl get pods; rm -rf /tmp/x",
            "kubectl get pods && touch /tmp/x",
            "kubectl get pods | sh",
            "kubectl get pods > /tmp/x",
            "kubectl get pods $(id)",
            "kubectl get pods\ntouch /tmp/x",
            "cd /tmp && kubectl get pods",
            "true || flux get all",
        ):
            assert decide(tool, command) == "reject", (tool, command)
        for command in (
            "kubectl delete pod x",
            "kubectl exec -it x -- sh",
            "kubectl port-forward x 80",
            "kubectl --kubeconfig=/tmp/x get pods",
            "flux reconcile kustomization apps",
            "rg flux /etc",
            "systemctl edit jellyfin",
            "systemctl mask jellyfin",
            "systemctl daemon-reload",
            "systemctl restart jellyfin; rm -rf /tmp/x",
            "journalctl -u jellyfin | sh",
            "systemctl status $(id)",
        ):
            assert decide(tool, command) == "built-in", (tool, command)

    # The kubeconfig and its token are amp's alone, and threads find both and the tools.
    assert host.succeed("stat -c '%U %a' $(readlink -f /etc/amp-runner/kubeconfig)").strip() == "amp 400"
    host.fail("su -s /bin/sh other -c 'cat /etc/amp-runner/kubeconfig'")
    host.fail("su -s /bin/sh other -c 'cat /run/kube-token'")
    assert host.succeed(f"cat {probe}/kubeconfig.out") == "/run/kube-token", host.succeed(f"cat {probe}/kubeconfig.out")
    assert host.succeed(f"cat {probe}/kube-token.out") == "test-kube-token", host.succeed(f"cat {probe}/kube-token.out")
    assert result("flux") == "ok", host.succeed(f"cat {probe}/flux.out")

    # Threads find the host's own tools, not just the runner's.
    assert result("system-tools") == "ok", host.succeed(f"cat {probe}/system-tools.out")

    # Threads use the Nix daemon to build, but are not trusted by it.
    assert result("nix-daemon") == "ok", host.succeed(f"cat {probe}/nix-daemon.out")
    assert "Trusted: 0" in host.succeed(f"cat {probe}/nix-daemon.out"), host.succeed(f"cat {probe}/nix-daemon.out")

    # The token reaches the runner, but amp cannot read the file it came from.
    assert result("key") == "sgamp_test_token", result("key")
    assert result("token-file") == "denied"

    # From inside the service, amp queues a deployment of merged main and reads its result.
    assert result("deploy") == "ok", host.succeed(f"cat {probe}/deploy.out")
    assert "queued" in host.succeed(f"cat {probe}/deploy.out")
    host.wait_until_succeeds("test -e /run/deployed")
    assert "No deployment has run yet" in host.succeed(f"cat {probe}/status.out")
    out = host.succeed("su -s /bin/sh amp -c 'host-deploy log'")
    assert "deployed deploy" in out, out
    # amp reads the host's journal, for debugging other services.
    host.wait_until_succeeds("journalctl -u other-logger | grep -q other-entry")
    host.succeed("su -s /bin/sh amp -c 'journalctl --no-pager -u other-logger' | grep -q other-entry")

    # amp manages other units on the host, but not protected ones, and only through the four
    # verbs: no kill and no transient units.
    # No transient units, so nothing runs as root; no targets, slices or isolation, which would
    # reach protected units through their dependencies.
    assert result("restart-other") == "ok", host.succeed(f"cat {probe}/restart-other.out")
    for name in ("restart-protected", "kill-other", "transient", "transient-named", "stop-sysinit", "isolate", "stop-slice"):
        assert result(name) == "denied", (name, host.succeed(f"cat {probe}/{name}.out"))
    host.fail("test -e /run/transient-ran")
    host.fail(as_amp("stop other-dependency.service"))
    host.succeed("systemctl is-active other-protected.service other-dependency.service sshd.service multi-user.target")

    # Nothing else: no protected units, no privileges, no host secrets, no writes outside its state.
    for name in ("restart-sshd", "stop-deploy", "sudo", "host-key", "write-etc"):
        assert result(name) == "denied", (name, host.succeed(f"cat {probe}/{name}.out"))
    host.fail("test -e /etc/injected")
    host.fail("su -s /bin/sh amp -c 'host-deploy restart-vm test'")

    # State snapshots: the state directory must be its own subvolume first.
    host.succeed(
        "mkfs.btrfs -q /dev/vdb && mkdir -p /mnt/data && mount /dev/vdb /mnt/data",
        "install -d -o other -m 0750 /mnt/data/state/app && echo before > /mnt/data/state/app/db",
        "systemctl start app.service",
    )
    host.fail(as_amp("start state-snapshot.service"))
    assert "not a btrfs subvolume" in host.succeed("journalctl -u state-snapshot --no-pager")
    # The one-time conversion, as modules/state-snapshot.nix gives it.
    host.succeed(
        "systemctl stop app.service && cd /mnt/data/state && d=app &&"
        " btrfs subvolume create $d.new && cp -a --reflink=always $d/. $d.new/ &&"
        " chown --reference=$d $d.new && chmod --reference=$d $d.new &&"
        " mv $d $d.pre-subvolume && mv $d.new $d && rm -r $d.pre-subvolume",
        "systemctl start app.service",
    )
    assert host.succeed("stat -c '%i %U %a' /mnt/data/state/app").strip() == "256 other 750"

    # Snapshots other than this unit's, which expiry and pruning must keep: another subvolume's
    # read-only snapshot under the prefix, a writable one of the state, and a read-only one of the
    # state under another name.
    host.succeed(
        "install -d -m 0700 /mnt/data/.snapshots && btrfs subvolume create /mnt/data/other",
        "btrfs subvolume snapshot -r /mnt/data/other /mnt/data/.snapshots/app-decoy-other",
        "btrfs subvolume snapshot /mnt/data/state/app /mnt/data/.snapshots/app-decoy-writable",
        "btrfs subvolume snapshot -r /mnt/data/state/app /mnt/data/.snapshots/manual-app",
    )
    decoys = "app-decoy-other app-decoy-writable manual-app"

    def snapshots():
        return set(host.succeed("ls /mnt/data/.snapshots").split()) - set(decoys.split())

    pid = host.succeed("systemctl show -p MainPID --value app.service").strip()
    host.succeed(as_amp("start state-snapshot.service"))
    # The service stopped for the snapshot and runs again.
    host.succeed("systemctl is-active app.service")
    assert host.succeed("systemctl show -p MainPID --value app.service").strip() != pid
    (first,) = snapshots()
    assert first.startswith("app-") and first.endswith("-app"), first
    assert host.succeed(f"cat /mnt/data/.snapshots/{first}/db").strip() == "before"
    assert host.succeed(f"btrfs property get -ts /mnt/data/.snapshots/{first} ro").strip() == "ro=true"
    host.succeed("echo after > /mnt/data/state/app/db")

    # Expiry keeps snapshots younger than 14 days, then deletes the old one only.
    host.succeed("systemctl start state-snapshot-expire.service")
    assert snapshots() == {first}
    host.succeed("date -s @$(( $(date +%s) + 15 * 86400 ))")
    host.succeed(as_amp("start state-snapshot.service"))
    (second,) = snapshots() - {first}
    host.succeed("systemctl start state-snapshot-expire.service")
    assert snapshots() == {second}, snapshots()
    # Pruning deletes this unit's remaining snapshot and nothing else.
    host.succeed(as_amp("start state-snapshot-prune.service"))
    assert snapshots() == set(), snapshots()
    for decoy in decoys.split():
        host.succeed(f"test -d /mnt/data/.snapshots/{decoy}")
    assert host.succeed("cat /mnt/data/state/app/db").strip() == "after"

    # Ops' path still queues deployments while both exist.
    host.succeed("rm /run/deployed")
    host.succeed("su -s /bin/sh ops-deploy -c 'systemctl --no-ask-password start --no-block agent-deploy.service'")
    host.wait_until_succeeds("test -e /run/deployed")

    # A runner that exits comes back by itself.
    before = host.succeed("systemctl show amp-runner -p InvocationID --value").strip()
    host.succeed("systemctl kill --signal=KILL amp-runner.service")
    host.wait_until_succeeds(f"test $(systemctl show amp-runner -p InvocationID --value) != {before}")
    host.wait_for_unit("amp-runner.service")

    # In a VM, the key arrives as a system credential from the host.
    guest.wait_until_succeeds(f"test -e {probe}/finished")
    def guest_result(name):
        return guest.succeed(f"cat {probe}/{name}").strip()
    assert guest_result("user") == "amp", guest_result("user")
    assert guest_result("key") == "sgamp_vm_token", guest_result("key")
    # Without host-deploy, the runner has no deployment command and only its own rules.
    assert guest_result("status") == "denied", guest.succeed(f"cat {probe}/status.out")
    assert guest_result("deploy") == "denied", guest.succeed(f"cat {probe}/deploy.out")
    guest.fail("systemctl cat agent-deploy.service")
    args = guest.succeed(f"cat {probe}/args").split()
    settings = json.loads(guest.succeed(f"cat {args[args.index('--settings-file') + 1]}"))
    assert settings["amp.permissions"] == [{"tool": "*", "action": "ask"}], settings
    for name in ("sudo", "host-key", "write-etc"):
        assert guest_result(name) == "denied", (name, guest.succeed(f"cat {probe}/{name}.out"))

    # An empty credential leaves the runner skipped, not failed.
    pending.wait_for_unit("multi-user.target")
    assert pending.succeed("systemctl show amp-runner.service -p ConditionResult --value").strip() == "no"
    assert pending.succeed("systemctl list-units --failed --no-legend --plain").strip() == "", pending.succeed("systemctl --failed")
    pending.fail(f"test -e {probe}")
  '';
}
