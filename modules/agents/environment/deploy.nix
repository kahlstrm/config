{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment.deploy;
  runner = lib.getExe cfg.package;
  command = pkgs.writeShellApplication {
    name = "agent-deploy";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if [ "$#" -ne 0 ]; then
        echo 'Usage: agent-deploy (merged upstream main only)' >&2
        exit 1
      fi
      systemctl --no-ask-password start --no-block agent-deploy.service
      echo 'Deployment queued. Inspect systemctl status agent-deploy and /nix/var/nix/profiles/agent-deploy/status.json.'
    '';
  };
in
{
  imports = [ ./deploy-options.nix ];
  config = lib.mkIf cfg.enable {
    system.switch.enable = true;
    system.nixos-init.enable = lib.mkIf (cfg.bootMode == "host") false;
    environment.systemPackages = [ command ];
    programs.ssh.knownHosts."github.com" = lib.mkIf (cfg.bootMode == "system") {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    systemd.tmpfiles.rules = [ "d /nix/var/nix/profiles/agent-deploy 0755 root root -" ];
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id === "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") === "agent-deploy.service" &&
              action.lookup("verb") === "start" &&
              ${builtins.toJSON cfg.requesters}.indexOf(subject.user) >= 0) {
            return polkit.Result.YES;
          }
        });
      '';
    };
    systemd.services.agent-deploy = {
      description = "Deploy the agent environment from merged upstream main";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      restartIfChanged = false;
      stopIfChanged = false;
      environment = {
        NIX_REMOTE = "daemon";
      }
      # A host's configuration reads the private secrets repository as a flake input
      # (`secrets` in flake.nix). The host fetches it with its own SSH host key, which that
      # repository lists as a read-only deploy key.
      // lib.optionalAttrs (cfg.bootMode == "system") {
        GIT_SSH_COMMAND = "${lib.getExe pkgs.openssh} -i /etc/ssh/ssh_host_ed25519_key -o IdentitiesOnly=yes";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${runner} deploy";
        TimeoutStartSec = "45min";
        UMask = "0022";
      };
    };
    system.systemBuilderCommands = lib.mkIf (cfg.bootMode == "host") ''
      printf '%s' ${lib.escapeShellArg (builtins.toJSON config.boot.kernelParams)} > "$out/agent-boot-parameters"
      printf '%s' ${lib.escapeShellArg (builtins.toJSON cfg.hostCompatibility)} > "$out/agent-host-configuration"
    '';
    # Stage 2 runs before systemd starts, so restored units are used immediately.
    boot.postBootCommands = lib.mkIf (cfg.bootMode == "host") (
      lib.mkAfter ''
        ${runner} restore
      ''
    );
  };
}
