{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment;
  github = config.local.agentGithub;
  instructions = pkgs.writeText "agent-instructions.md" (
    lib.concatStringsSep "\n\n" [
      (builtins.readFile ../../../config/AGENTS.md)
      (builtins.readFile ./instructions.md)
    ]
  );
in
{
  imports = [
    ./deploy-options.nix
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
    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };
    t3Port = lib.mkOption {
      type = lib.types.port;
      default = 3773;
    };
    t3Package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      default = pkgs.t3code.override {
        enableCodex = false;
        enableClaude = false;
        enableOpencode = false;
        gh = if github.enable then github.package else pkgs.gh;
      };
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
  };
}
