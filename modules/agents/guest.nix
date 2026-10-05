{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentVm;
  github = config.local.agentGithub;
  settings = cfg.settings;
  network = settings.network;
  agentHome = config.users.users.agent.home;
  configurationRepository = "config";
  configuration = "${github.upstreamOwner}/${configurationRepository}";
  configCheckout = "${agentHome}/config";
  workspaces = "${agentHome}/workspaces";
  sshHostKey = "/var/lib/ssh/ssh_host_ed25519_key";
  t3 = pkgs.t3code.override {
    enableClaude = true;
    enableOpencode = true;
    gh = if github.enable then github.package else pkgs.gh;
  };
  instructions = ./instructions.md;
in
{
  options.local.agentVm = {
    settings = lib.mkOption {
      type = lib.types.attrs;
      default = import ./settings.nix;
      internal = true;
      description = "Shared host and guest topology.";
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    revision = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
    };
    networkServices = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Host-enforced service exceptions advertised to agents.";
    };
  };
  config = {
    system.stateVersion = "26.05";
    networking.hostName = "agents";
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    networking.nameservers = lib.mkDefault [ network.hostAddress ];
    systemd.network.networks."10-agent" = {
      matchConfig.MACAddress = network.mac;
      address = [ "${network.guestAddress}/${toString network.prefixLength}" ];
      routes = [ { Gateway = network.hostAddress; } ];
      networkConfig.IPv6AcceptRA = false;
    };
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
      settings.t3Port
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
      codex
      claude-code
      opencode
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
      isolation = {
        hostShares = [ ];
        egress = "public HTTP/HTTPS and configured DNS; private destinations otherwise blocked except allowedServices";
        dnsServers = config.networking.nameservers;
        allowedServices = cfg.networkServices;
        deployment = "operator only";
      };
      github = {
        inherit (github) forkOwner upstreamOwner;
        enabled = github.enable;
      };
      versions = {
        t3 = t3.version;
        codex = pkgs.codex.version;
        claude = pkgs.claude-code.version;
      };
      resources = {
        vcpus = config.microvm.vcpu or null;
        memoryMiB = config.microvm.mem or null;
        disks = map (volume: { inherit (volume) mountPoint size; }) (config.microvm.volumes or [ ]);
      };
    };
    environment.etc."agent-instructions.md".source = instructions;
    systemd.tmpfiles.rules =
      map (path: "d ${path} 0700 agent users -") [
        workspaces
        "${agentHome}/.codex"
        "${agentHome}/.claude"
        "${agentHome}/.config"
        "${agentHome}/.config/opencode"
      ]
      ++ map (path: "L+ ${agentHome}/${path} - agent users - /etc/agent-instructions.md") [
        "AGENTS.md"
        ".codex/AGENTS.md"
        ".claude/CLAUDE.md"
        ".config/opencode/AGENTS.md"
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
        ExecStart = "${t3}/bin/t3 serve --host ${network.guestAddress} --port ${toString settings.t3Port}";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        NoNewPrivileges = true;
        TasksMax = 2048;
      };
    };
  };
}
