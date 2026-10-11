{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  github = config.local.agentGithub;
  agentHome = config.users.users.agent.home;
  configurationRepository = "config";
  configuration = "${github.upstreamOwner}/${configurationRepository}";
  configCheckout = "${agentHome}/config";
  workspaces = "${agentHome}/workspaces";
  agentSkills = ../../../config/agents/skills;
  skillNames = builtins.attrNames (builtins.readDir agentSkills);
  sshHostKey = "/var/lib/ssh/ssh_host_ed25519_key";
  t3 = pkgs.t3code.override {
    enableCodex = false;
    enableClaude = false;
    enableOpencode = false;
    gh = if github.enable then github.package else pkgs.gh;
  };
  instructions = pkgs.writeText "agent-instructions.md" (
    lib.concatStringsSep "\n\n" [
      (builtins.readFile ../../../config/AGENTS.md)
      (builtins.readFile ./instructions.md)
    ]
  );
in
{
  imports = [
    ./tooling.nix
    ./deploy.nix
    ../../agent-github
  ];
  options.local.agentEnvironment = {
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };
    t3Port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
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
  };
  config = {
    system.stateVersion = lib.mkDefault "26.05";
    users.mutableUsers = false;
    # The only login is the unprivileged agent's SSH key; root stays locked.
    users.allowNoPasswordLogin = true;
    users.users.agent = {
      isNormalUser = true;
      home = "/home/agent";
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          path = sshHostKey;
          type = "ed25519";
        }
      ];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [ "agent" ];
      };
    };
    networking.firewall.allowedTCPPorts = [
      22
      cfg.t3Port
    ];
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "root" ];
      auto-optimise-store = false;
    };
    nix.gc = {
      automatic = true;
      options = "--delete-older-than 14d";
    };
    programs.nix-ld.enable = true;
    environment.systemPackages = with pkgs; [
      t3
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
    programs.git = {
      enable = true;
      config = {
        user.name = "${github.forkOwner} (bot)";
        user.email = "${github.forkUserId}+${github.forkOwner}@users.noreply.github.com";
        init.defaultBranch = "main";
      };
    };
    environment.etc."agent-environment.json".text = builtins.toJSON {
      inherit (cfg) revision;
      inherit configuration configCheckout workspaces;
      instructions = "/etc/agent-instructions.md";
      services = [ "t3code" ];
      inherit (cfg) isolation resources;
      deployment = {
        enabled = cfg.deploy.enable;
        source = "merged upstream main";
        target = if cfg.deploy.enable then cfg.deploy.configuration else null;
        bootMode = if cfg.deploy.enable then cfg.deploy.bootMode else null;
      };
      github = {
        inherit (github) forkOwner upstreamOwner;
        enabled = github.enable;
      };
      versions = {
        t3 = t3.version;
      };
      tools = {
        installation = "agent-tools.service bootstraps native installers into the persistent agent home";
        updates = "provider updaters or T3 Settings > Providers; inspect CLI --version for installed versions";
      };
    };
    environment.etc."agent-instructions.md".source = instructions;
    environment.etc."agent-skills".source = agentSkills;
    systemd.tmpfiles.rules =
      # The persistent /home volume mounts after user activation creates homes.
      map (path: "d ${path} 0700 agent users -") [
        agentHome
        workspaces
        "${agentHome}/.agents"
        "${agentHome}/.agents/skills"
        "${agentHome}/.codex"
        "${agentHome}/.claude"
        "${agentHome}/.claude/skills"
        "${agentHome}/.config"
        "${agentHome}/.config/opencode"
      ]
      ++ map (path: "L+ ${agentHome}/${path} - agent users - /etc/agent-instructions.md") [
        "AGENTS.md"
        ".codex/AGENTS.md"
        ".claude/CLAUDE.md"
        ".config/opencode/AGENTS.md"
      ]
      ++
        lib.concatMap
          (
            directory:
            map (
              name: "L+ ${agentHome}/${directory}/${name} - agent users - /etc/agent-skills/${name}"
            ) skillNames
          )
          [
            ".agents/skills"
            ".claude/skills"
          ]
      ++ [ "d ${builtins.dirOf sshHostKey} 0700 root root -" ];
    age.identityPaths = [ sshHostKey ];
    systemd.services.agent-workspace = {
      description = "Initialize the agent's environment configuration checkout";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.coreutils
      ];
      environment.HOME = agentHome;
      serviceConfig = {
        User = "agent";
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        UMask = "0077";
      };
      script = ''
        if [ ! -d ${lib.escapeShellArg configCheckout} ]; then
          temporary=$(mktemp -d ${lib.escapeShellArg "${agentHome}/.config-checkout.XXXXXX"})
          trap 'rm -rf "$temporary"' EXIT
          git clone ${lib.escapeShellArg "https://github.com/${configuration}.git"} "$temporary"
          git -C "$temporary" remote rename origin upstream
          git -C "$temporary" remote add origin ${lib.escapeShellArg "https://github.com/${github.forkOwner}/${configurationRepository}.git"}
          mv "$temporary" ${lib.escapeShellArg configCheckout}
        fi
      '';
    };
    systemd.services.t3code = {
      description = "T3 coding agent server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = config.environment.systemPackages;
      environment.HOME = agentHome;
      serviceConfig = {
        User = "agent";
        WorkingDirectory = agentHome;
        ExecStart = "${t3}/bin/t3 serve --host ${cfg.bindAddress} --port ${toString cfg.t3Port}";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        NoNewPrivileges = true;
        TasksMax = 2048;
      };
    };
  };
}
