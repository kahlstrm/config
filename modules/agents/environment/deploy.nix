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
    systemd.tmpfiles.rules = [ "d /nix/var/nix/profiles/agent-deploy 0755 root root -" ];
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id === "org.freedesktop.systemd1.manage-units" &&
              ["agent-deploy.service", "agent-deploy-log.service"].indexOf(action.lookup("unit")) >= 0 &&
              action.lookup("verb") === "start" &&
              ${builtins.toJSON cfg.requesters}.indexOf(subject.user) >= 0) {
            return polkit.Result.YES;
          }
        });
      '';
    };
    # Requesters read agent-deploy's journal through this copy, not the journal itself, which
    # would show them every service's logs. `host-deploy log` refreshes and prints it.
    users.groups.agent-deploy-log = { };
    users.users = lib.genAttrs cfg.requesters (_: {
      extraGroups = [ "agent-deploy-log" ];
    });
    systemd.services.agent-deploy-log = {
      description = "Copy agent-deploy's recent journal for its requesters";
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "agent-deploy-log";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = true;
        Group = "agent-deploy-log";
        UMask = "0027";
      };
      script = ''
        ${config.systemd.package}/bin/journalctl --unit agent-deploy.service --lines 200 --no-pager \
          --output short-iso > /run/agent-deploy-log/log.tmp
        mv /run/agent-deploy-log/log.tmp /run/agent-deploy-log/log
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
