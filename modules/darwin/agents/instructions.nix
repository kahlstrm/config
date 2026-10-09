{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentHost.instructions;
  host = config.local.agentHost;
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;

  instructions = pkgs.writeText "agent-instructions.md" (
    lib.concatStringsSep "\n\n" [
      (builtins.readFile ../../../config/AGENTS.md)
      (builtins.readFile ./instructions.md)
    ]
  );

  logs =
    lib.optionalAttrs host.deploy.enable { deploy = "/var/log/darwin-deploy.log"; }
    // lib.optionalAttrs host.t3.enable {
      t3 = "${home}/Library/Logs/t3.log";
      tailscaleServe = "/var/log/t3-tailscale-serve.log";
    }
    // lib.optionalAttrs host.doctor.enable { doctor = "${home}/Library/Logs/t3-doctor.log"; };

  # Describes only the enabled parts of the host.
  manifest = {
    revision = config.system.configurationRevision;
    inherit user logs;
    instructions = "/etc/agent-instructions.md";
  }
  // lib.optionalAttrs host.deploy.enable {
    configuration = {
      name = host.deploy.configuration;
      checkout = host.deploy.repository;
      inherit (cfg) github;
    };
    sudo = {
      passwordless = [
        "darwin-deploy [--rollback | --variant <name>]"
        "tailscale up"
        "trace-process [-f filesys|network|pathname|exec|diskio|cachehit] [-t seconds] <pid> (fs_usage)"
      ];
      everythingElse = "requires the user's password; ask them";
      reboot = "human only (FileVault)";
    };
  }
  // lib.optionalAttrs host.t3.enable {
    t3 = {
      inherit (host.t3) port previewPorts;
      service = "svc:${host.t3.serviceName}";
      previewService = "svc:${host.t3.previewServiceName}";
      version = host.t3.package.version;
      access =
        if host.t3.tailscale then
          "https://${host.t3.serviceName}.<tailnet>, previews at https://${host.t3.previewServiceName}.<tailnet>:<port> (Tailscale Services); T3 listens on 127.0.0.1"
        else
          "http://${config.networking.localHostName}.local:${toString host.t3.port} on the LAN";
    };
    harnesses = {
      claude = "${home}/.local/bin/claude";
      codex = "${home}/.local/bin/codex";
      opencode = "${home}/.opencode/bin/opencode";
      management = "installed and updated by T3 (Settings > Providers) or native updaters, not Nix";
    };
  }
  // lib.optionalAttrs host.doctor.enable {
    checks = [ "t3-doctor" ];
  }
  // lib.optionalAttrs host.opper.enable {
    opper = {
      claudeConfig = "${home}/.claude-opper";
      inherit (host.opper) claudeModels;
      opencodeModels = lib.attrNames host.opper.opencodeModels;
    };
  };
in
{
  options.local.agentHost.instructions = {
    enable = lib.mkEnableOption "agent instructions and environment manifest";
    github = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "owner/nix-config";
      description = "GitHub repository of this configuration, for the manifest.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."agent-instructions.md".source = instructions;
    environment.etc."agent-environment.json".text = builtins.toJSON manifest;

    # The general instructions plus this host's section replace the plain
    # AGENTS.md links for every harness.
    home-manager.users.${user} = {
      home.file = lib.genAttrs [ ".claude/CLAUDE.md" ".codex/AGENTS.md" ] (_: {
        source = lib.mkForce instructions;
      });
      xdg.configFile."opencode/AGENTS.md".source = lib.mkForce instructions;
    };
  };
}
