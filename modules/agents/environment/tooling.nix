{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  tools = cfg.provisioning.tools;
in
{
  config = {
    programs.nix-ld.libraries = [ pkgs.alsa-lib ];
    environment.systemPackages = with pkgs; [
      bubblewrap
      procps
      socat
    ];
    environment.shellInit = ''
      export PATH="${tools.path}$PATH"
    '';
    systemd.services.agent-tools = {
      description = "Install writable coding agent CLIs";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.HOME = cfg.home;
      path = tools.runtime;
      serviceConfig = {
        User = cfg.user;
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        TimeoutStartSec = "15min";
        UMask = "0077";
        NoNewPrivileges = true;
      };
      script = tools.script;
    };
    systemd.services.t3code.environment.PATH = lib.mkForce (
      tools.path + lib.makeBinPath config.environment.systemPackages + ":/run/current-system/sw/bin"
    );
  };
}
