{
  config,
  lib,
  pkgs,
  ...
}:
let
  command = pkgs.writeShellApplication {
    name = "agent-store-repair";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if [ "$#" -ne 0 ]; then
        echo 'Usage: agent-store-repair' >&2
        exit 1
      fi
      systemctl --no-ask-password start --no-block agent-store-repair.service
      echo 'Repair queued. Inspect systemctl status agent-store-repair and /var/log/agent-store-repair/repair.log.'
    '';
  };
in
{
  environment.systemPackages = [ command ];
  security.polkit = {
    enable = true;
    extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") === "agent-store-repair.service" &&
            action.lookup("verb") === "start" &&
            subject.user === "${config.local.agentEnvironment.user or "agent"}") {
          return polkit.Result.YES;
        }
      });
    '';
  };
  systemd.services.agent-store-repair = {
    description = "Verify and repair the guest Nix store using configured caches";
    restartIfChanged = false;
    stopIfChanged = false;
    environment = {
      HOME = "/var/empty";
      NIX_USER_CONF_FILES = "/dev/null";
      NIX_REMOTE = "daemon";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${config.nix.package}/bin/nix-store --verify --check-contents --repair";
      TimeoutStartSec = "45min";
      UMask = "0022";
      LogsDirectory = "agent-store-repair";
      LogsDirectoryMode = "0755";
      StandardOutput = "append:/var/log/agent-store-repair/repair.log";
      StandardError = "inherit";
    };
  };
}
