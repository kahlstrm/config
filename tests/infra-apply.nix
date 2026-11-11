# infra-apply's boundary on a host with an Amp runner: the runner user amp starts a layer's plan
# through polkit and reads its output, but cannot read the layer's key, checkout or plan, cannot
# use sudo, cannot start a layer the host does not list, and cannot stop or restart the units,
# neither through polkit nor through the runner's unit rules. Without network the plan fails at
# its first fetch, which shows it ran as the layer's own user.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "infra-apply";
  nodes.host = {
    imports = [ ../modules/infra-apply ];
    system.stateVersion = "26.05";
    local.infraApply.layers.local-networking = {
      serviceAccount = "infra-local-networking@p.iam.gserviceaccount.com";
      keyId = "abc";
    };
    # The runner's rules and user, as on the hosts. It stays skipped without a key.
    local.ampRunner = {
      enable = true;
      package = pkgs.hello;
    };
  };
  testScript = ''
    host.wait_for_unit("infra-credentials-local-networking.service")
    state = "/var/lib/infra-apply/local-networking"
    host.succeed(f"test -s {state}/gcp.key -a -s {state}/gcp.json")
    host.succeed(f"grep -q infra-local-networking@p.iam.gserviceaccount.com {state}/gcp.json")
    assert host.succeed(f"stat -c %U {state}").strip() == "infra-local-networking"

    def as_amp(command):
        return f"su -s /bin/sh amp -c {command!r} 2>&1"

    for path in [f"{state}/gcp.key", f"{state}/gcp.json"]:
        host.fail(as_amp(f"cat {path}"))
    host.fail(as_amp(f"ls {state}"))
    host.fail(as_amp("/run/wrappers/bin/sudo -n true"))

    # Started through polkit, the plan runs as the layer's user and fails at its first fetch,
    # and amp sees why.
    status, output = host.execute(as_amp("infra-apply plan local-networking"))
    assert status != 0, output
    assert "infra-apply:" in output and "git clone" in output, output
    assert "Access denied" not in output and "authentication required" not in output, output
    host.fail(as_amp("infra-apply plan local-talos"))

    for command in [
        "start infra-plan@local-talos.service",
        "start infra-apply@local-talos.service",
        "stop infra-plan@local-networking.service",
        "restart infra-apply@local-networking.service",
        "stop infra-credentials-local-networking.service",
        "restart infra-credentials-local-networking.service",
    ]:
        output = host.fail(as_amp(f"systemctl --no-ask-password {command}"))
        assert "authentication required" in output or "Access denied" in output, output
  '';
}
