# An Amp runner on this host: `amp --no-tui` connects out to ampcode.com, so threads started
# there (from a Space, an orb, the web or the phone) can run commands here.
#
# The runner runs as the unprivileged amp user. On a host it has two privileged actions:
# - host-deploy (./host-deploy-command.nix): queue agent-deploy of this machine's own
#   configuration from merged upstream main, and read its status and log. Merging to main is
#   the review, so the runner's permission rules allow it without approval.
# - Unit management, for debugging: polkit lets amp start, stop, restart and reload any unit
#   on the host except the protected ones below, which would cut the runner or maintainers
#   off the host, interrupt a deployment, power the host down or drop its firewall. A reboot
#   is `systemctl start reboot.target`. The runner's rules ask before each of these four
#   verbs and allow `systemctl status|show|list-units` and `journalctl` without a prompt; amp
#   reads every journal through the systemd-journal group. Unit edits, masks and
#   daemon-reload stay root's. `readOnlyUnits` start without a prompt, for root units that
#   only read, such as a listing of a directory amp cannot read.
# Other commands follow Amp's built-in rules, which allow read-only commands, builds and
# running code and ask for the rest. Those rules guide the agent; since running code needs no
# approval, a thread can manage units without a prompt too. The boundary is the amp user,
# which gets no sudo, no units beyond the ones above, and no writes outside its state
# directory. A runner without host-deploy (`hostDeploy = false`, as on ops) gets neither
# action and decides its rules entirely through `extraPermissions`.
#
# With `kubernetesTokenFile`, the runner is also the break-glass read path into klusse while the
# in-cluster klusse runner is down: a kubeconfig for a read-only ServiceAccount, whose RBAC is the
# boundary, as the permission rules for kubectl and flux only spare the prompts.
#
# The token is an Amp access key (`sgamp_…`), installed by hand in systemd's credential store
# (see `tokenFile`), passed in by a VM's host as a system credential, or from an agenix secret.
# systemd hands it to the service as a credential, so amp cannot read the stored file; the
# runner's own environment holds it.
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
  hostCommands = lib.optional cfg.hostDeploy command;
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
  shellRule =
    action: patterns: extra:
    map (
      { tool, field }:
      {
        inherit tool action;
        matches.${field} = patterns;
      }
      // extra
    ) shellTools;
  kubernetes = cfg.kubernetesTokenFile != null;
  protectedUnits = [
    "amp-runner.service"
    "agent-deploy.service"
    "sshd.service"
    "sshd.socket"
    "polkit.service"
    "dbus.service"
    "dbus.socket"
    "dbus-broker.service"
    "nix-daemon.service"
    "nix-daemon.socket"
    "firewall.service"
    "nftables.service"
    "NetworkManager.service"
    "systemd-networkd.service"
    "tailscaled.service"
    "poweroff.target"
    "halt.target"
    "kexec.target"
    "exit.target"
    "rescue.target"
    "emergency.target"
    "sleep.target"
    "suspend.target"
    "hibernate.target"
    "hybrid-sleep.target"
    "suspend-then-hibernate.target"
    "systemd-poweroff.service"
    "systemd-halt.service"
    "systemd-kexec.service"
    "systemd-exit.service"
    "systemd-suspend.service"
    "systemd-hibernate.service"
    "systemd-hybrid-sleep.service"
    "systemd-suspend-then-hibernate.service"
    "rescue.service"
    "emergency.service"
  ]
  ++ cfg.protectedUnits;
  # One shell word: unquoted without shell syntax, or single-quoted.
  word = "([A-Za-z0-9@._:,=+*/-]+|'[^']*')";
  kubeconfig = "/etc/amp-runner/kubeconfig";
  api = import ./agents/vm/settings.nix;
  # User rules are checked before Amp's built-in ones, which decide everything else.
  # Read-only kubectl and flux run as single commands: one led or followed by a shell operator,
  # redirect, substitution or newline is rejected before the allow rule sees it.
  permissions =
    lib.optionals cfg.hostDeploy (
      shellRule "allow" [
        "host-deploy deploy"
        "host-deploy status"
        "host-deploy log"
      ] { }
    )
    ++ lib.optionals kubernetes (
      shellRule "reject" [
        ''/^\s*(kubectl|flux)\s[\s\S]*[;&|<>`$\n]|[;&|(`\n]\s*(kubectl|flux)(\s|$)/''
      ] { message = "Run kubectl and flux as single commands, without pipes, redirects or chaining."; }
      ++ shellRule "allow" [
        ''/^(kubectl( +(-n|--namespace)[ =][a-z0-9-]+| +(-A|--all-namespaces))* (get|describe|logs|top|events|api-resources|api-versions|explain|version|auth can-i)|flux( +(-n|--namespace)[ =][a-z0-9-]+| +(-A|--all-namespaces))* (get|logs|events|tree|trace|stats|version))( +([^;&|`$<>()\\'"\s]|'[^']*')+)*$/''
      ] { }
    )
    ++ cfg.extraPermissions
    ++ lib.optionals cfg.hostDeploy (
      shellRule "allow" (map (unit: "systemctl start ${unit}") cfg.readOnlyUnits) { }
      ++ shellRule "ask" [ "/^systemctl +(start|stop|restart|reload)( +${word})+$/" ] { }
      ++ shellRule "allow" [
        "/^systemctl +(status|show|list-units)( +${word})*$/"
        "/^journalctl( +${word})*$/"
      ] { }
    );
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
    enable = lib.mkEnableOption "an Amp runner on this machine";
    hostDeploy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the runner may deploy this machine from merged upstream main with host-deploy,
        without approval. Without it, the runner gets no deployment rights and no permission
        rules besides `extraPermissions`.
      '';
    };
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
        `systemd-creds encrypt --name=${credential} - /etc/credstore.encrypted/${credential}`,
        or from the system credentials a VM's host passes in. Without either, it uses an
        account saved by `amp login` as ${user}.
      '';
    };
    kubernetesTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Runtime path of a read-only klusse ServiceAccount token, readable only by ${user}. When
        set, the runner gets kubectl, flux and a kubeconfig for that token in `KUBECONFIG`, and
        read-only kubectl and flux commands run without approval.
      '';
    };
    extraPermissions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = "Further `amp.permissions` rules, checked after host-deploy's and before the unit rules and Amp's built-in rules.";
    };
    protectedUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "microvm@ops.service" ];
      description = ''
        Units on this host that amp may not start, stop, restart or reload, besides the ones
        every host protects. List a unit's Requires= and PartOf= targets too: stopping or
        restarting one of them stops or restarts the unit.
      '';
    };
    readOnlyUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Root units that only read, which the runner starts without a prompt.";
    };
  };
  config = lib.mkIf cfg.enable {
    local.agentEnvironment.deploy = lib.mkIf cfg.hostDeploy {
      enable = true;
      inherit (cfg) configuration;
      bootMode = "system";
      requesters = [ user ];
    };
    security.polkit.extraConfig = lib.mkIf cfg.hostDeploy ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.user === ${builtins.toJSON user} &&
            ["start", "stop", "restart", "reload"].indexOf(action.lookup("verb")) >= 0 &&
            ${builtins.toJSON protectedUnits}.indexOf(action.lookup("unit")) < 0) {
          return polkit.Result.YES;
        }
      });
    '';
    environment.systemPackages =
      hostCommands
      ++ lib.optionals kubernetes [
        pkgs.kubectl
        pkgs.fluxcd
      ];
    environment.etc."amp-runner/kubeconfig" = lib.mkIf kubernetes {
      user = user;
      group = user;
      mode = "0400";
      text = builtins.toJSON {
        apiVersion = "v1";
        kind = "Config";
        clusters = [
          {
            name = "klusse";
            cluster = {
              server = "https://${api.kubernetesApiHostname}:${toString (builtins.head api.allowedServices.kubernetes-api.tcpPorts)}";
              certificate-authority = ../secrets/agent-kubernetes-ca.crt;
            };
          }
        ];
        users = [
          {
            name = "break-glass-reader";
            user.tokenFile = cfg.kubernetesTokenFile;
          }
        ];
        contexts = [
          {
            name = "break-glass-reader";
            context = {
              cluster = "klusse";
              user = "break-glass-reader";
            };
          }
        ];
        current-context = "break-glass-reader";
      };
    };
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
      unitConfig = {
        ConditionPathExists = map (path: "|${path}") (
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
        # A VM's host passes the key in as a system credential, an empty one until it is
        # installed.
        ConditionFileNotEmpty = lib.mkIf (cfg.tokenFile == null) "|/run/credentials/@system/${credential}";
      };
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # The host's own tools, as a login shell on it would have them.
      path = hostCommands ++ [
        "/run/current-system/sw"
        config.nix.package
        pkgs.git
        pkgs.coreutils
        pkgs.bash
      ];
      environment.HOME = home;
      environment.KUBECONFIG = lib.mkIf kubernetes kubeconfig;
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
