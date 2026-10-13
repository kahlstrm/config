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
  sshHostKey = "/var/lib/ssh/ssh_host_ed25519_key";
in
{
  imports = [
    ./tooling.nix
    ./deploy.nix
    ./store-repair.nix
  ];
  config = {
    system.stateVersion = lib.mkDefault "26.05";
    users.mutableUsers = false;
    # The only login is the unprivileged agent's SSH key; root stays locked.
    users.allowNoPasswordLogin = true;
    users.users.${cfg.user} = {
      isNormalUser = true;
      home = "/home/${cfg.user}";
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
        AllowUsers = [ cfg.user ];
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
    programs.git = {
      enable = true;
      config = {
        user.name = "${github.forkOwner} (bot)";
        user.email = "${github.forkUserId}+${github.forkOwner}@users.noreply.github.com";
        init.defaultBranch = "main";
      };
    };
    systemd.tmpfiles.rules =
      # The persistent /home volume mounts after user activation creates homes.
      map (path: "d ${path} 0700 ${cfg.user} users -") [
        cfg.home
        cfg.workspaces
        "${cfg.home}/.agents"
        "${cfg.home}/.agents/skills"
        "${cfg.home}/.codex"
        "${cfg.home}/.claude"
        "${cfg.home}/.claude/skills"
        "${cfg.home}/.config"
        "${cfg.home}/.config/opencode"
      ]
      ++ map (path: "L+ ${cfg.home}/${path} - ${cfg.user} users - /etc/agent-instructions.md") [
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
              name: "L+ ${cfg.home}/${directory}/${name} - ${cfg.user} users - /etc/agent-skills/${name}"
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
      environment.HOME = cfg.home;
      serviceConfig = {
        User = cfg.user;
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        UMask = "0077";
      };
      script = ''
        if [ ! -d ${lib.escapeShellArg cfg.configCheckout} ]; then
          temporary=$(mktemp -d ${lib.escapeShellArg "${cfg.home}/.config-checkout.XXXXXX"})
          trap 'rm -rf "$temporary"' EXIT
          git clone ${lib.escapeShellArg "https://github.com/${cfg.configuration}.git"} "$temporary"
          git -C "$temporary" remote rename origin upstream
          git -C "$temporary" remote add origin ${lib.escapeShellArg "https://github.com/${github.forkOwner}/${baseNameOf cfg.configuration}.git"}
          mv "$temporary" ${lib.escapeShellArg cfg.configCheckout}
        fi
      '';
    };
    systemd.services.t3code = {
      description = "T3 coding agent server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = config.environment.systemPackages;
      environment.HOME = cfg.home;
      serviceConfig = {
        User = cfg.user;
        WorkingDirectory = cfg.home;
        ExecStart = "${cfg.t3Package}/bin/t3 serve --host ${cfg.bindAddress} --port ${toString cfg.t3Port}";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        NoNewPrivileges = true;
        TasksMax = 2048;
      };
    };
  };
}
