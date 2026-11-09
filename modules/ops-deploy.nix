# Lets the ops VM deploy this machine from merged upstream main, and nothing else.
#
# Ops' deploy key (lib/ssh-keys.nix `deployers.ops`) logs in as ops-deploy, whose forced
# command is host-deploy (./host-deploy-command.nix): deploy, status, log, and restart-vm for
# a VM in `restartableVMs` (pannu's agent VMs), which returns at once so ops can restart itself.
# The key gets no shell, forwarding or other command, and polkit lets ops-deploy start that
# one unit and restart those VMs only. Whoever merges to main already controls this machine
# and its VM images, so the key adds the timing of a deployment, not new access.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.opsDeploy;
  user = "ops-deploy";
  command = pkgs.callPackage ./host-deploy-command.nix {
    inherit (cfg) configuration restartableVMs;
  };
in
{
  imports = [ ./agents/environment/deploy.nix ];
  options.local.opsDeploy = {
    enable = lib.mkEnableOption "deployments of merged upstream main requested by the ops VM";
    configuration = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      default = config.networking.hostName;
      description = "The nixosConfigurations entry this machine deploys.";
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = (import ../lib/ssh-keys.nix).deployers.ops;
      description = "Public keys that may log in as ${user}, each with the forced command.";
    };
    restartableVMs = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z][a-z0-9-]*");
      default = [ ];
      description = "microvm.nix VMs whose microvm@<name> unit ${user} may restart, to boot a staged image.";
    };
    exclusiveFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Source addresses, such as ops' own, that may log in as ${user} only.";
    };
  };
  config = lib.mkIf cfg.enable {
    local.agentEnvironment.deploy = {
      enable = true;
      inherit (cfg) configuration;
      bootMode = "system";
      requesters = [ user ];
    };
    security.polkit.extraConfig = lib.mkIf (cfg.restartableVMs != [ ]) ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            ${
              builtins.toJSON (map (vm: "microvm@${vm}.service") cfg.restartableVMs)
            }.indexOf(action.lookup("unit")) >= 0 &&
            action.lookup("verb") === "restart" && subject.user === ${builtins.toJSON user}) {
          return polkit.Result.YES;
        }
      });
    '';
    users.groups.${user} = { };
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      # sshd runs the forced command through the login shell; nologin would refuse it.
      useDefaultShell = true;
      # Reads the deployment's journal for `log`; the forced command chooses what it shows.
      extraGroups = [ "systemd-journal" ];
      openssh.authorizedKeys.keys = map (
        key: ''restrict,command="${lib.getExe command}" ${key}''
      ) cfg.authorizedKeys;
    };
    services.openssh.extraConfig = lib.mkIf (cfg.exclusiveFrom != [ ]) ''
      Match Address ${lib.concatStringsSep "," cfg.exclusiveFrom}
        AllowUsers ${user}
        PasswordAuthentication no
        KbdInteractiveAuthentication no
    '';
  };
}
