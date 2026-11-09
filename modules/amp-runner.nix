# An Amp runner on this host: `amp --no-tui` connects out to ampcode.com, so threads started
# there (from a Space, an orb, the web or the phone) can run commands here.
#
# The runner runs as the unprivileged amp user. Its one privileged action is host-deploy
# (./host-deploy-command.nix): queue agent-deploy of this machine's own configuration from
# merged upstream main, and read its status and log. Merging to main is the review, so the
# runner's permission rules allow host-deploy without approval; other commands follow Amp's
# built-in rules, which allow read-only commands, builds and running code and ask for the
# rest. Those rules guide the agent; the boundary is the amp user, which gets no sudo, no
# other units, and no writes outside its state directory.
#
# The token is an Amp access key (`sgamp_…`), installed by hand in systemd's credential store
# (see `tokenFile`) or from an agenix secret. systemd hands it to the service as a credential,
# so amp cannot read the stored file; the runner's own environment holds it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.ampRunner;
  user = "amp";
  home = "/var/lib/amp-runner";
  credential = "amp-runner.token";
  command = pkgs.callPackage ./host-deploy-command.nix { inherit (cfg) configuration; };
  shellTools = [
    {
      tool = "Bash";
      field = "cmd";
    }
    {
      tool = "async_shell_command";
      field = "command";
    }
    {
      tool = "shell_command";
      field = "command";
    }
  ];
  # User rules are checked before Amp's built-in ones, which decide everything else.
  permissions =
    map (
      { tool, field }:
      {
        inherit tool;
        action = "allow";
        matches.${field} = [
          "host-deploy deploy"
          "host-deploy status"
          "host-deploy log"
        ];
      }
    ) shellTools
    ++ cfg.extraPermissions;
  settings = pkgs.writeText "amp-runner-settings.json" (
    builtins.toJSON { "amp.permissions" = permissions; }
  );
  start = pkgs.writeShellApplication {
    name = "amp-runner";
    text = ''
      token="''${CREDENTIALS_DIRECTORY:-}/${credential}"
      if [ -r "$token" ]; then
        AMP_API_KEY="$(< "$token")"
        export AMP_API_KEY
      fi
      exec ${lib.getExe cfg.package} --no-tui --runner-id ${lib.escapeShellArg cfg.runnerId} \
        --settings-file ${settings}
    '';
  };
in
{
  imports = [ ./agents/environment/deploy.nix ];
  options.local.ampRunner = {
    enable = lib.mkEnableOption "an Amp runner that may deploy this machine from merged upstream main";
    configuration = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      default = config.networking.hostName;
      description = "The nixosConfigurations entry this machine deploys.";
    };
    runnerId = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9]([a-z0-9-]*[a-z0-9])?";
      default = config.networking.hostName;
      description = "The runner's stable ID, shown in Amp's location picker.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.amp-cli;
      defaultText = lib.literalExpression "pkgs.amp-cli";
      description = "The Amp CLI.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File holding the Amp access key the runner signs in with, readable by root only, such
        as an agenix secret. Without it, the runner imports the credential `${credential}`
        from systemd's credential stores, where it is installed by hand, preferably encrypted:
        `systemd-creds encrypt --name=${credential} - /etc/credstore.encrypted/${credential}`.
        Without either, it uses an account saved by `amp login` as ${user}.
      '';
    };
    extraPermissions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Further `amp.permissions` rules, checked after host-deploy and before Amp's built-in rules.";
    };
  };
  config = lib.mkIf cfg.enable {
    local.agentEnvironment.deploy = {
      enable = true;
      inherit (cfg) configuration;
      bootMode = "system";
      requesters = [ user ];
    };
    environment.systemPackages = [ command ];
    users.groups.${user} = { };
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      inherit home;
      createHome = true;
      # Threads on the runner start login shells for their commands.
      useDefaultShell = true;
      # Reads the host's journal: agent-deploy's for `host-deploy log`, and others for debugging.
      extraGroups = [ "systemd-journal" ];
    };
    # Threads build and evaluate configurations through the daemon, as an untrusted user.
    nix.settings.allowed-users = [ user ];
    systemd.services.amp-runner = {
      description = "Amp runner ${cfg.runnerId}";
      wantedBy = [ "multi-user.target" ];
      # amp exits at once without a key or a saved login, and a unit that fails during a switch
      # makes agent-deploy roll the host back. Skip the runner until one of them exists.
      unitConfig.ConditionPathExists = map (path: "|${path}") (
        if cfg.tokenFile != null then
          [ (toString cfg.tokenFile) ]
        else
          [
            "/etc/credstore.encrypted/${credential}"
            "/etc/credstore/${credential}"
            "/run/credstore.encrypted/${credential}"
            "/run/credstore/${credential}"
          ]
          ++ [ "${home}/.local/share/amp/secrets.json" ]
      );
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # The host's own tools, as a login shell on it would have them.
      path = [
        command
        "/run/current-system/sw"
        config.nix.package
        pkgs.git
        pkgs.coreutils
        pkgs.bash
      ];
      environment.HOME = home;
      serviceConfig = {
        User = user;
        Group = user;
        WorkingDirectory = home;
        ExecStart = lib.getExe start;
        LoadCredential = lib.mkIf (cfg.tokenFile != null) [ "${credential}:${cfg.tokenFile}" ];
        ImportCredential = lib.mkIf (cfg.tokenFile == null) [ credential ];
        Restart = "always";
        RestartSec = 10;
        StateDirectory = "amp-runner";
        StateDirectoryMode = "0700";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
