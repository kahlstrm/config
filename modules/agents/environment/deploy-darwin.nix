{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment.deploy;
  request = pkgs.writeShellApplication {
    name = "agent-deploy-request";
    text = ''
      [ "$#" -eq 0 ] || { echo 'agent-deploy accepts no arguments' >&2; exit 2; }
      exec /bin/launchctl kickstart system/org.nixos.agent-deploy
    '';
  };
  command = pkgs.writeShellApplication {
    name = "agent-deploy";
    text = ''
      if [ "$#" -ne 0 ]; then
        echo 'Usage: agent-deploy (merged upstream main only)' >&2
        exit 1
      fi
      /usr/bin/sudo -n /run/current-system/sw/bin/agent-deploy-request
      echo 'Deployment queued. Inspect /nix/var/nix/profiles/agent-deploy/status.json and /var/log/agent-deploy.log.'
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.bootMode == "system";
        message = "macOS agent deployment requires bootMode = system.";
      }
    ];
    environment.systemPackages = [
      request
      command
      cfg.package
    ];
    security.sudo.extraConfig = ''
      ${config.local.agentEnvironment.user} ALL=(root) NOPASSWD: /run/current-system/sw/bin/agent-deploy-request ""
    '';
    system.activationScripts.preActivation.text = ''
      install -d -m 0755 /nix/var/nix/profiles/agent-deploy
    '';
    # A stable executable path keeps activation from unloading its own worker.
    launchd.daemons.agent-deploy.serviceConfig = {
      Label = "org.nixos.agent-deploy";
      ProgramArguments = [
        "/run/current-system/sw/bin/agent-deploy-runner"
        "deploy"
      ];
      EnvironmentVariables = {
        HOME = "/var/root";
        NIX_REMOTE = "daemon";
      };
      StandardOutPath = "/var/log/agent-deploy.log";
      StandardErrorPath = "/var/log/agent-deploy.log";
    };
  };
}
