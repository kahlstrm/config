{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentGithub;
  credentials = pkgs.callPackage ./package.nix { };
in
{
  options.local.agentGithub.sync.enable =
    lib.mkEnableOption "automatic synchronization of configured forks";

  config = lib.mkIf (cfg.enable && cfg.sync.enable) {
    systemd.services.agent-fork-sync = {
      description = "Synchronize agent forks with their upstream repositories";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "agent";
        ExecStart = "${credentials}/bin/agent-credentials sync";
        TimeoutStartSec = "5min";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        PrivateTmp = true;
      };
    };
    systemd.timers.agent-fork-sync = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitInactiveSec = "15min";
      };
    };
  };
}
