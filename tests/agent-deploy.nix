{ pkgs }:
let
  node =
    bootMode:
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      fixture = pkgs.writeShellScriptBin "git" ''
        set -eu
        test "$*" = 'ls-remote --exit-code https://github.com/kahlstrm/config.git refs/heads/main'
        if [ -f /var/lib/reject-main ]; then
          printf '%040d\trefs/heads/agent-change\n' 1
          exit
        fi
        printf '%040d\trefs/heads/main\n' 1
      '';
      builder = pkgs.writeShellScriptBin "nix" ''
        set -eu
        test "$1" = build
        test "$2" = 'github:kahlstrm/config/0000000000000000000000000000000000000001#nixosConfigurations.agents.config.system.build.toplevel'
        test "$3" = --out-link
        test "$5" = --print-out-paths
        if [ -f /var/lib/reject-build ]; then exit 1; fi
        touch /run/agent-build-started
        while [ -e /var/lib/hold-build ]; do sleep 0.1; done
        selection=updated
        if [ -f /var/lib/deploy-selection ]; then selection=$(cat /var/lib/deploy-selection); fi
        system=$(readlink -f "$(readlink -f /run/booted-system)/specialisation/$selection")
        ln -sfn "$system" "$4"
        echo "$system"
      '';
    in
    {
      imports = [ ../modules/agents/environment/deploy.nix ];
      system.stateVersion = "26.05";
      users.users.agent.isNormalUser = true;
      local.agentEnvironment.deploy = {
        enable = true;
        configuration = "agents";
        inherit bootMode;
        package = pkgs.callPackage ../modules/agents/environment/deploy-package.nix {
          git = fixture;
          nix = pkgs.runCommand "deployment-build-fixture" { } ''
            mkdir -p "$out/bin"
            ln -s ${builder}/bin/nix "$out/bin/nix"
            ln -s ${config.nix.package}/bin/nix-env "$out/bin/nix-env"
          '';
          repository = "kahlstrm/config";
          configuration = "agents";
          inherit bootMode;
        };
      };
      environment.etc."deployment-marker".text = "baseline";
      system.build.installBootLoader = lib.mkIf (bootMode == "system") (
        lib.mkForce (
          pkgs.writeShellScript "bootloader-fixture" ''
            echo "$1" > /var/lib/installed-system
          ''
        )
      );
      specialisation.updated.configuration = {
        environment.etc."deployment-marker".text = lib.mkForce "updated";
        system.activationScripts.restoreFailure.text = ''
          if [ -e /nix/var/nix/profiles/agent-deploy/reject-restore ]; then exit 1; fi
        '';
      };
      specialisation.broken.configuration = {
        environment.etc."deployment-marker".text = lib.mkForce "broken";
        system.activationScripts.deploymentFailure.text = "exit 1";
      };
      specialisation.bootChange.configuration.boot.kernelParams = [ "agent-test-changed" ];
      virtualisation.memorySize = 2048;
    };
in
pkgs.testers.runNixOSTest {
  name = "agent-deploy";
  nodes = {
    machine = node "host";
    native = node "system";
  };
  testScript = ''
    import json
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("polkit.service")
    machine.fail("su - agent -c 'agent-deploy unmerged-commit'")
    machine.fail("su - agent -c 'systemctl --no-ask-password stop agent-deploy.service'")
    machine.fail("su - agent -c 'systemctl --no-ask-password start sshd.service'")
    machine.fail("su - agent -c 'touch /nix/var/nix/profiles/agent-deploy/injected'")
    machine.succeed("touch /var/lib/hold-build")
    machine.succeed("systemd-run --unit=agent-session --uid=agent --property=NoNewPrivileges=yes --setenv=PATH=/run/current-system/sw/bin /run/current-system/sw/bin/bash -c 'agent-deploy; sleep infinity'")
    machine.wait_until_succeeds("test -e /run/agent-build-started")
    machine.succeed("systemctl stop agent-session; rm /var/lib/hold-build")
    machine.wait_until_succeeds("test $(cat /etc/deployment-marker) = updated")
    machine.wait_until_succeeds("test $(systemctl show agent-deploy -p ActiveState --value) = inactive")
    status = json.loads(machine.succeed("cat /nix/var/nix/profiles/agent-deploy/status.json"))
    assert status["state"] == "succeeded"
    assert status["revision"] == "0" * 39 + "1"
    machine.succeed("test -L /nix/var/nix/profiles/agent-deploy/current")
    machine.succeed("nix-store --gc --print-roots | grep /nix/var/nix/profiles/agent-deploy/current-")
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test $(cat /etc/deployment-marker) = updated")
    machine.succeed("touch /var/lib/reject-main")
    machine.succeed("su - agent -c agent-deploy")
    machine.wait_until_succeeds("systemctl is-failed agent-deploy.service")
    machine.succeed("test $(cat /etc/deployment-marker) = updated")
    status = json.loads(machine.succeed("cat /nix/var/nix/profiles/agent-deploy/status.json"))
    assert "Upstream main" in status["error"]
    machine.succeed("echo bootChange > /var/lib/deploy-selection; rm /var/lib/reject-main")
    machine.succeed("su - agent -c agent-deploy")
    machine.wait_until_succeeds("systemctl is-failed agent-deploy.service")
    machine.succeed("test $(cat /etc/deployment-marker) = updated")
    status = json.loads(machine.succeed("cat /nix/var/nix/profiles/agent-deploy/status.json"))
    assert "operator" in status["error"]
    machine.succeed("echo broken > /var/lib/deploy-selection")
    machine.succeed("su - agent -c agent-deploy")
    machine.wait_until_succeeds("systemctl is-failed agent-deploy.service")
    machine.succeed("test $(cat /etc/deployment-marker) = updated")
    machine.succeed("test $(readlink -f /nix/var/nix/profiles/agent-deploy/current) = $(readlink -f /run/current-system)")
    machine.succeed("touch /var/lib/reject-build")
    machine.succeed("su - agent -c agent-deploy")
    machine.wait_until_succeeds("systemctl is-failed agent-deploy.service")
    machine.succeed("test $(cat /etc/deployment-marker) = updated")
    machine.succeed("touch /nix/var/nix/profiles/agent-deploy/reject-restore")
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test $(cat /etc/deployment-marker) = baseline")
    status = json.loads(machine.succeed("cat /nix/var/nix/profiles/agent-deploy/status.json"))
    assert status["state"] == "restore-failed"
    machine.succeed("rm /nix/var/nix/profiles/agent-deploy/reject-restore")
    native.start()
    native.wait_for_unit("multi-user.target")
    native.wait_for_unit("polkit.service")
    native.succeed("su - agent -c agent-deploy")
    native.wait_until_succeeds("test $(cat /etc/deployment-marker) = updated")
    native.wait_until_succeeds("test $(systemctl show agent-deploy -p ActiveState --value) = inactive")
    native.succeed("test $(cat /etc/deployment-marker) = updated")
    native.succeed("test $(readlink -f /nix/var/nix/profiles/system) = $(readlink -f /run/current-system)")
    native.succeed("test $(cat /var/lib/installed-system) = $(readlink -f /run/current-system)")
    native.succeed("echo broken > /var/lib/deploy-selection")
    native.succeed("su - agent -c agent-deploy")
    native.wait_until_succeeds("systemctl is-failed agent-deploy.service")
    native.succeed("test $(cat /etc/deployment-marker) = updated")
    native.succeed("test $(readlink -f /nix/var/nix/profiles/system) = $(readlink -f /run/current-system)")
    native.succeed("test $(cat /var/lib/installed-system) = $(readlink -f /run/current-system)")
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test $(cat /etc/deployment-marker) = updated")
    machine.succeed("ln -sfn $(readlink -f /run/current-system) /nix/var/nix/profiles/agent-deploy/base")
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test $(cat /etc/deployment-marker) = baseline")
  '';
}
