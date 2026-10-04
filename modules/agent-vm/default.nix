{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentVm;
  t3 = pkgs.t3code.override {
    enableClaude = true;
    enableOpencode = true;
    gh = if config.local.agentGithub.enable then config.local.agentGithub.package else pkgs.gh;
  };
  instructions = ./instructions.md;
in
{
  options.local.agentVm = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    revision = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
    };
  };
  config = {
    system.stateVersion = "26.05";
    networking.hostName = "agents";
    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.enableIPv6 = false;
    networking.nameservers = [
      "9.9.9.9"
      "149.112.112.112"
    ];
    systemd.network.networks."10-agent" = {
      matchConfig.MACAddress = "02:00:00:83:00:02";
      address = [ "10.83.0.2/30" ];
      routes = [ { Gateway = "10.83.0.1"; } ];
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
          path = "/var/lib/ssh/ssh_host_ed25519_key";
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
      3773
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
        user.name = "kahlstrm-agents";
        user.email = "kahlstrm-agents@users.noreply.github.com";
        init.defaultBranch = "main";
      };
    };
    environment.etc."agent-environment.json".text = builtins.toJSON {
      inherit (cfg) revision;
      configuration = "kahlstrm/config";
      configCheckout = "/home/agent/config";
      workspaces = "/home/agent/workspaces";
      instructions = "/etc/agent-instructions.md";
      services = [ "t3code" ];
      isolation = {
        hostShares = [ ];
        egress = "public HTTP/HTTPS and Quad9 DNS; no LAN, host, or tailnet";
        deployment = "operator only";
      };
      github = {
        enabled = config.local.agentGithub.enable or false;
        forkOwner = "kahlstrm-agents";
        upstreamOwner = "kahlstrm";
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
    systemd.tmpfiles.rules = [
      "d /home/agent/workspaces 0700 agent users -"
      "d /home/agent/.codex 0700 agent users -"
      "d /home/agent/.claude 0700 agent users -"
      "d /home/agent/.config 0700 agent users -"
      "d /home/agent/.config/opencode 0700 agent users -"
      "L+ /home/agent/AGENTS.md - agent users - /etc/agent-instructions.md"
      "L+ /home/agent/.codex/AGENTS.md - agent users - /etc/agent-instructions.md"
      "L+ /home/agent/.claude/CLAUDE.md - agent users - /etc/agent-instructions.md"
      "L+ /home/agent/.config/opencode/AGENTS.md - agent users - /etc/agent-instructions.md"
      "d /var/lib/ssh 0700 root root -"
    ];
    age.identityPaths = [ "/var/lib/ssh/ssh_host_ed25519_key" ];
    systemd.services.agent-workspace = {
      description = "Initialize the agent's environment configuration checkout";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        pkgs.git
        pkgs.coreutils
      ];
      environment.HOME = "/home/agent";
      serviceConfig = {
        User = "agent";
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = 60;
        UMask = "0077";
      };
      script = ''
        if [ ! -d /home/agent/config ]; then
          temporary=$(mktemp -d /home/agent/.config-checkout.XXXXXX)
          trap 'rm -rf "$temporary"' EXIT
          git clone https://github.com/kahlstrm/config.git "$temporary"
          git -C "$temporary" remote rename origin upstream
          git -C "$temporary" remote add origin https://github.com/kahlstrm-agents/config.git
          mv "$temporary" /home/agent/config
        fi
      '';
    };
    systemd.services.t3code = {
      description = "T3 coding agent server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = config.environment.systemPackages;
      environment.HOME = "/home/agent";
      serviceConfig = {
        User = "agent";
        WorkingDirectory = "/home/agent";
        ExecStart = "${t3}/bin/t3 serve --host 10.83.0.2 --port 3773";
        Restart = "on-failure";
        RestartSec = 5;
        UMask = "0077";
        NoNewPrivileges = true;
        TasksMax = 2048;
      };
    };
  };
}
