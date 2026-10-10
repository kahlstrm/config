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
  options.local.agentEnvironment.deploy = {
    enable = lib.mkEnableOption "deployment of merged upstream main inside the agent environment";
    repository = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
      default = "kahlstrm/config";
    };
    configuration = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = "Fixed nixosConfigurations target; callers cannot override it.";
    };
    bootMode = lib.mkOption {
      type = lib.types.enum [
        "host"
        "system"
      ];
      default = "system";
      description = "Host-provided VM boot image or native NixOS bootloader.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      default = pkgs.callPackage ./deploy-package.nix {
        inherit (cfg) repository configuration bootMode;
        nix = config.nix.package;
      };
    };
  };
  config = lib.mkIf cfg.enable {
    system.switch.enable = true;
    system.nixos-init.enable = lib.mkIf (cfg.bootMode == "host") false;
    environment.systemPackages = [ command ];
    systemd.tmpfiles.rules = [ "d /nix/var/nix/profiles/agent-deploy 0755 root root -" ];
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id === "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") === "agent-deploy.service" &&
              action.lookup("verb") === "start" && subject.user === "agent") {
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
        HOME = "/var/empty";
        NIX_REMOTE = "daemon";
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
    '';
    # Stage 2 runs before systemd starts, so restored units are used immediately.
    boot.postBootCommands = lib.mkIf (cfg.bootMode == "host") (
      lib.mkAfter ''
        ${runner} restore
      ''
    );
  };
}
