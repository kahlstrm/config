# Ops' deploy key on a host: it logs in as ops-deploy, whose forced command only queues
# agent-deploy for the host's own configuration from merged upstream main, or reports its
# status and log. On pannu it may also restart a named agent VM to boot its staged image.
# Any other command, a shell, port forwarding and other units are refused, and on pannu
# ops' address may log in only as ops-deploy.
{ pkgs }:
let
  # nixpkgs' fixed test keys; generating them would make evaluation read a build output.
  keys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
in
pkgs.testers.runNixOSTest {
  name = "agent-ops-deploy";
  nodes = {
    ops = { };
    host =
      {
        lib,
        pkgs,
        nodes,
        ...
      }:
      {
        imports = [ ../modules/ops-deploy.nix ];
        system.stateVersion = "26.05";
        services.openssh.enable = true;
        users.users.admin = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
        };
        local.opsDeploy = {
          enable = true;
          configuration = "host";
          authorizedKeys = [ keys.snakeOilPublicKey ];
          restartableVMs = [ "test" ];
          # The test network adds IPv6, which pannu's tap drops.
          exclusiveFrom = [
            nodes.ops.networking.primaryIPAddress
            nodes.ops.networking.primaryIPv6Address
          ];
        };
        # Stand-ins for agent VMs: one ops may restart, one it may not.
        systemd.services."microvm@test" = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
        systemd.services."microvm@other" = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
        # The runner itself is covered by the agent-deploy test; this records that it ran.
        local.agentEnvironment.deploy.package = lib.mkForce (
          pkgs.writeShellScriptBin "agent-deploy-runner" ''
            mkdir -p /nix/var/nix/profiles/agent-deploy
            echo '{"state": "succeeded", "revision": "0000000000000000000000000000000000000001"}' > /nix/var/nix/profiles/agent-deploy/status.json
            echo "deployed $1"
            touch /run/deployed
          ''
        );
      };
  };
  testScript = ''
    start_all()
    host.wait_for_unit("sshd.service")
    host.wait_for_unit("multi-user.target")
    ops.wait_for_unit("multi-user.target")
    ops.succeed("install -m 0400 ${keys.snakeOilPrivateKey} /root/deploy")
    ops.succeed("install -m 0400 ${keys.snakeOilEd25519PrivateKey} /root/other")
    # CI's store files are not owned by root, so ssh would refuse systemd's ssh_config.d drop-in;
    # -n keeps ssh from reading the test driver's commands on stdin.
    ssh = "ssh -n -F /dev/null -o StrictHostKeyChecking=no -o BatchMode=yes -i /root/deploy ops-deploy@host"
    ops.wait_until_succeeds(f"{ssh} status")

    # Before any deployment, status reports that none has run.
    out = ops.succeed(f"{ssh} status")
    assert "No deployment has run yet" in out, out
    out = ops.succeed(f"{ssh} deploy")
    assert "queued" in out, out
    host.wait_until_succeeds("test -e /run/deployed")
    out = ops.succeed(f"{ssh} status")
    assert '"succeeded"' in out and "ActiveState=inactive" in out, out
    out = ops.succeed(f"{ssh} log")
    assert "deployed deploy" in out, out

    # The forced command ignores what the client asks for beyond the three verbs.
    host.succeed("rm /run/deployed")
    ops.fail(f"{ssh} 'deploy; touch /tmp/injected'")
    ops.fail(f"{ssh} 'systemctl start sshd.service'")
    ops.fail(f"{ssh} 'id'")
    ops.fail(f"{ssh} ")
    host.fail("test -e /tmp/injected")
    host.fail("test -e /run/deployed")
    # Forwarding is refused: the local listener opens, but no connection gets through it.
    ops.succeed(f"{ssh} -f -N -L 2222:localhost:22")
    ops.wait_until_succeeds("ss -ltn | grep -q 127.0.0.1:2222")
    ops.fail("timeout 10 ssh-keyscan -p 2222 127.0.0.1 2>/dev/null | grep -q ssh-")
    # restart-vm restarts exactly the named, listed VM, so it boots its staged image.
    def invocation(unit):
        return host.succeed(f"systemctl show {unit} -p InvocationID --value").strip()
    test_before, other_before = invocation("microvm@test"), invocation("microvm@other")
    out = ops.succeed(f"{ssh} 'restart-vm test'")
    assert "test" in out, out
    host.wait_until_succeeds(f"test $(systemctl show microvm@test -p InvocationID --value) != {test_before}")
    host.wait_for_unit("microvm@test.service")
    for request in ("restart-vm other", "restart-vm", "restart-vm test other", "restart-vm 'test'", "restart-vm ../test"):
        ops.fail(f"{ssh} \"{request}\"")
    assert invocation("microvm@other") == other_before
    host.fail("su -s /bin/sh ops-deploy -c 'systemctl --no-ask-password restart microvm@other.service'")
    host.fail("su -s /bin/sh ops-deploy -c 'systemctl --no-ask-password stop microvm@test.service'")
    # ops-deploy may queue agent-deploy and nothing else.
    host.fail("su -s /bin/sh ops-deploy -c 'systemctl --no-ask-password restart sshd.service'")
    host.fail("su -s /bin/sh ops-deploy -c 'systemctl --no-ask-password stop agent-deploy.service'")

    # From ops' address no other account logs in, even with its own key.
    ops.fail("ssh -n -F /dev/null -o StrictHostKeyChecking=no -o BatchMode=yes -i /root/other admin@host true")
    host.succeed("install -m 0400 ${keys.snakeOilEd25519PrivateKey} /root/other")
    host.succeed("ssh -n -F /dev/null -o StrictHostKeyChecking=no -o BatchMode=yes -i /root/other admin@localhost true")
  '';
}
