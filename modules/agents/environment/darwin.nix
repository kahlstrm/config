{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  logs = "${cfg.home}/Library/Logs";
  workspace = pkgs.writeShellApplication {
    name = "agent-workspace";
    runtimeInputs = [
      pkgs.git
      pkgs.coreutils
    ];
    text = cfg.provisioning.workspaceScript;
  };
in
{
  imports = [ ./deploy-darwin.nix ];
  config = {
    system.primaryUser = lib.mkDefault cfg.user;
    users.users.${cfg.user} = {
      home = lib.mkDefault "/Users/${cfg.user}";
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    services.openssh = {
      enable = true;
      extraConfig = ''
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
        AllowUsers ${cfg.user}
      '';
    };
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "root" ];
    };
    nix.gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
    environment.etc.gitconfig.text = lib.generators.toGitINI cfg.provisioning.gitConfig;
    # Activation runs as root; the home already exists for the primary user.
    system.activationScripts.postActivation.text = ''
      ${lib.concatMapStrings (path: ''
        install -d -m 0700 -o ${cfg.user} ${lib.escapeShellArg path}
      '') ([ logs ] ++ cfg.provisioning.directories)}
      ${lib.concatMapStrings (link: ''
        ln -sfn ${lib.escapeShellArg link.target} ${lib.escapeShellArg link.path}
        chown -h ${cfg.user} ${lib.escapeShellArg link.path}
      '') cfg.provisioning.links}
    '';
    launchd.user.agents.agent-workspace.serviceConfig = {
      ProgramArguments = [ (lib.getExe workspace) ];
      EnvironmentVariables.HOME = cfg.home;
      RunAtLoad = true;
      KeepAlive.SuccessfulExit = false;
      ThrottleInterval = 60;
      StandardOutPath = "${logs}/agent-workspace.log";
      StandardErrorPath = "${logs}/agent-workspace.log";
    };
    launchd.user.agents.t3code.serviceConfig = {
      ProgramArguments = [
        "${cfg.t3Package}/bin/t3"
        "serve"
        "--host"
        cfg.bindAddress
        "--port"
        (toString cfg.t3Port)
      ];
      WorkingDirectory = cfg.home;
      EnvironmentVariables = {
        HOME = cfg.home;
        PATH =
          "${cfg.home}/.local/bin:${cfg.home}/.opencode/bin:"
          + lib.makeBinPath config.environment.systemPackages
          + ":/usr/bin:/bin:/usr/sbin:/sbin";
      };
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 5;
      StandardOutPath = "${logs}/t3.log";
      StandardErrorPath = "${logs}/t3.log";
    };
    assertions = [
      {
        assertion = config.system.primaryUser == cfg.user;
        message = "launchd user agents run only in system.primaryUser's session; set it to the agent user.";
      }
    ];
  };
}
