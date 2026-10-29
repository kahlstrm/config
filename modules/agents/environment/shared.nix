{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  github = config.local.agentGithub;
  skillNames = builtins.attrNames (builtins.readDir ../../../config/agents/skills);
  t3code = import ../../../pkgs/t3code.nix { inherit (pkgs) lib t3code fetchFromGitHub; };
  # Agents only run `t3 serve`, so they get the bundled server without the desktop app.
  t3Server = pkgs.callPackage ../../../pkgs/t3code-server {
    t3code-unwrapped = t3code.unwrapped;
    resourceMonitor = t3code.resourceMonitor;
    runtimePackages = [
      (if github.enable then github.package else pkgs.gh)
      pkgs.git
    ];
  };
  ghExtensions = pkgs.linkFarm "agent-gh-extensions" (
    map (extension: {
      name = extension.pname;
      path = "${extension}/bin";
    }) (import ../../../lib/gh-extensions.nix pkgs)
  );
  instructions = pkgs.writeText "agent-instructions.md" (
    lib.concatStringsSep "\n\n" (
      [
        (builtins.readFile ../../../config/AGENTS.md)
        (builtins.readFile ./instructions.md)
      ]
      ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin (builtins.readFile ./darwin-instructions.md)
    )
  );
in
{
  imports = [
    ./deploy-options.nix
    ./tools.nix
    ../../agent-github
  ];
  options.local.agentEnvironment = {
    user = lib.mkOption {
      type = lib.types.strMatching "[a-z_][a-z0-9_-]*";
      default = "agent";
    };
    home = lib.mkOption {
      type = lib.types.str;
      default = config.users.users.${cfg.user}.home;
      defaultText = lib.literalExpression "config.users.users.\${user}.home";
    };
    configuration = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
      default = "${github.owner}/config";
      defaultText = lib.literalExpression ''"''${config.local.agentGithub.owner}/config"'';
      description = "Repository that manages this environment.";
    };
    configCheckout = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.home}/config";
      defaultText = lib.literalExpression ''"''${home}/config"'';
    };
    workspaces = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.home}/workspaces";
      defaultText = lib.literalExpression ''"''${home}/workspaces"'';
    };
    coAuthor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Name <email@example.com>";
      description = "Person credited with a Co-authored-by trailer on agent commits.";
    };
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };
    t3Port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
    };
    t3Settings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = {
        sidebarAutoSettleOnMerge = false;
        autoResumeLimitedThreads = true;
        branchNamingMode = "semantic";
        linkedEnvironmentsEnabled = true;
      };
      description = "T3 server settings merged into its settings.json at each start; other settings stay editable in the UI.";
    };
    t3Package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      default = t3Server;
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    revision = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
    };
    isolation = lib.mkOption {
      type = lib.types.attrs;
      default = {
        mode = "dedicated machine";
      };
      description = "Isolation capabilities supplied by the machine configuration.";
    };
    resources = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
    credentials = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Credentials provisioned for the agent beyond GitHub, by service.";
    };
    provisioning = {
      directories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        readOnly = true;
        default = [
          cfg.home
          cfg.workspaces
        ]
        ++ map (path: "${cfg.home}/${path}") [
          ".agents"
          ".agents/skills"
          ".codex"
          ".claude"
          ".claude/skills"
          ".config"
          ".config/opencode"
          ".local"
          ".local/share"
          ".local/share/gh"
        ];
      };
      links = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.str);
        internal = true;
        readOnly = true;
        description = "Home links to instructions, shared skills and gh extensions, in creation order.";
        default =
          map
            (path: {
              path = "${cfg.home}/${path}";
              target = "/etc/agent-instructions.md";
            })
            [
              "AGENTS.md"
              ".codex/AGENTS.md"
              ".claude/CLAUDE.md"
              ".config/opencode/AGENTS.md"
            ]
          ++
            lib.concatMap
              (
                directory:
                map (name: {
                  path = "${cfg.home}/${directory}/${name}";
                  target = "/etc/agent-skills/${name}";
                }) skillNames
              )
              [
                ".agents/skills"
                ".claude/skills"
              ]
          ++ [
            {
              path = "${cfg.home}/.local/share/gh/extensions";
              target = "/etc/agent-gh-extensions";
            }
          ];
      };
      gitConfig = lib.mkOption {
        type = lib.types.attrs;
        internal = true;
        readOnly = true;
        default = {
          user.name = github.bot.login;
          user.email = "${github.bot.userId}+${github.bot.login}@users.noreply.github.com";
          init.defaultBranch = "main";
        }
        # Configured hooks run alongside repository hooks, even when core.hooksPath is set.
        // lib.optionalAttrs (cfg.coAuthor != null) {
          hook.co-author = {
            event = "prepare-commit-msg";
            command = pkgs.writeShellScript "co-author" ''
              exec ${lib.getExe pkgs.git} interpret-trailers --in-place --if-exists addIfDifferent \
                --trailer ${lib.escapeShellArg "Co-authored-by: ${cfg.coAuthor}"} "$1"
            '';
          };
        };
      };
      workspaceScript = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        description = "Clones the configuration checkout on first start; needs git and coreutils.";
        default = ''
          if [ ! -d ${lib.escapeShellArg cfg.configCheckout} ]; then
            temporary=$(mktemp -d ${lib.escapeShellArg "${cfg.home}/.config-checkout.XXXXXX"})
            trap 'rm -rf "$temporary"' EXIT
            git clone ${lib.escapeShellArg "https://github.com/${cfg.configuration}.git"} "$temporary"
            mv "$temporary" ${lib.escapeShellArg cfg.configCheckout}
          fi
        '';
      };
      t3SettingsScript = lib.mkOption {
        type = lib.types.lines;
        internal = true;
        readOnly = true;
        description = "Merges t3Settings into T3's settings file; needs jq.";
        default = import ../../../lib/t3-settings.nix {
          inherit lib;
          jq = "jq";
          inherit (cfg) home;
          settings = cfg.t3Settings;
        };
      };
    };
  };
  config = {
    environment.systemPackages = with pkgs; [
      cfg.t3Package
      git
      gh
      jq
      curl
      ripgrep
      tmux
      nodejs_24
      python3
      nixfmt
    ];
    environment.etc."agent-environment.json".text = builtins.toJSON {
      inherit (cfg)
        revision
        configuration
        configCheckout
        workspaces
        ;
      instructions = "/etc/agent-instructions.md";
      services = [ "t3code" ];
      inherit (cfg) isolation resources credentials;
      deployment = {
        enabled = cfg.deploy.enable;
        source = "merged upstream main";
        target = if cfg.deploy.enable then cfg.deploy.configuration else null;
        bootMode = if cfg.deploy.enable then cfg.deploy.bootMode else null;
      };
      github = {
        inherit (github) owner;
        enabled = github.enable;
      };
      versions = {
        t3 = cfg.t3Package.version;
      };
      tools = {
        installation = "agent-tools.service bootstraps native installers into the persistent agent home";
        updates = "provider updaters or T3 Settings > Providers; inspect CLI --version for installed versions";
      };
    };
    environment.etc."agent-instructions.md".source = instructions;
    environment.etc."agent-skills".source = ../../../config/agents/skills;
    environment.etc."agent-gh-extensions".source = ghExtensions;
  };
}
