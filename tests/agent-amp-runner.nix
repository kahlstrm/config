# An Amp runner on a host runs as the unprivileged amp user. From inside its service it may
# queue agent-deploy of merged upstream main and read its status and log, without approval,
# but cannot manage other units, gain privileges, or read the host's secrets. Its token
# reaches the runner only through the service's credentials, and ops' deploy path keeps
# working beside it while both exist. The token here is installed by hand, encrypted with
# systemd-creds into the credential store, as on the hosts.
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
      probe sudo /run/wrappers/bin/sudo -n true
      probe host-key cat /etc/ssh/ssh_host_ed25519_key
      probe token-file cat /etc/credstore.encrypted/amp-runner.token
      probe write-etc touch /etc/injected
      echo finished > "$out/finished"
      exec sleep infinity
    '';
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
      ];
      system.stateVersion = "26.05";
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
  testScript = ''
    import json

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

    # The runner runs as amp with a stable runner ID and Nix-managed settings.
    assert result("user") == "amp", result("user")
    args = host.succeed(f"cat {probe}/args").split()
    assert args[:3] == ["--no-tui", "--runner-id", "host"], args
    settings = json.loads(host.succeed(f"cat {args[args.index('--settings-file') + 1]}"))
    rules = settings["amp.permissions"]
    shells = {"Bash", "shell_command", "async_shell_command"}
    # host-deploy is allowed without approval in every shell tool; anything else asks
    # before Amp's built-in allow rules can match it.
    for tool in shells:
        assert any(r["tool"] == tool and r["action"] == "allow" and "host-deploy" in json.dumps(r.get("matches")) for r in rules), rules
        assert {"tool": tool, "action": "ask"} in rules, rules
    assert [r for r in rules if r["tool"] in shells][-3:] == [{"tool": t, "action": "ask"} for t in sorted(shells)], rules

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

    # Nothing else: no other units, no privileges, no host secrets, no writes outside its state.
    for name in ("restart-sshd", "stop-deploy", "sudo", "host-key", "write-etc"):
        assert result(name) == "denied", (name, host.succeed(f"cat {probe}/{name}.out"))
    host.fail("test -e /etc/injected")
    host.fail("su -s /bin/sh amp -c 'host-deploy restart-vm test'")

    # Ops' path still queues deployments while both exist.
    host.succeed("rm /run/deployed")
    host.succeed("su -s /bin/sh ops-deploy -c 'systemctl --no-ask-password start --no-block agent-deploy.service'")
    host.wait_until_succeeds("test -e /run/deployed")

    # A runner that exits comes back by itself.
    before = host.succeed("systemctl show amp-runner -p InvocationID --value").strip()
    host.succeed("systemctl kill --signal=KILL amp-runner.service")
    host.wait_until_succeeds(f"test $(systemctl show amp-runner -p InvocationID --value) != {before}")
    host.wait_for_unit("amp-runner.service")
  '';
}
