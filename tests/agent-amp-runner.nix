# An Amp runner on a host runs as the unprivileged amp user. From inside its service it may
# queue agent-deploy of merged upstream main and read its status and log, without approval,
# but cannot manage other units, gain privileges, or read the host's secrets. Its token
# reaches the runner only through the service's credentials, and ops' deploy path keeps
# working beside it while both exist.
{ pkgs }:
let
  # Stands in for the Amp CLI: records how it was started, then probes what a thread on
  # the runner could do from inside the service, and stays up like a runner.
  fakeAmp = pkgs.writeShellApplication {
    name = "amp";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
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
      probe token-file cat /etc/amp-runner-token
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
      environment.etc."amp-runner-token" = {
        text = "sgamp_test_token";
        mode = "0400";
      };
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
        tokenFile = "/etc/amp-runner-token";
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
    host.wait_for_unit("amp-runner.service")
    host.wait_until_succeeds("test -e /var/lib/amp-runner/probe/finished")
    probe = "/var/lib/amp-runner/probe"

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
