{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentGithub;
  credentials = pkgs.callPackage ./package.nix { };
  helper = pkgs.writeShellApplication {
    name = "git-credential-agent";
    text = ''exec ${credentials}/bin/agent-credentials git "$@"'';
  };
  gh = pkgs.writeShellApplication {
    name = "gh";
    runtimeInputs = [
      pkgs.git
    ];
    text = ''exec ${credentials}/bin/agent-credentials gh ${pkgs.gh}/bin/gh "$@"'';
  };
in
{
  options.local.agentGithub = {
    enable = lib.mkEnableOption "GitHub App credentials for agent branches and PRs";
    package = lib.mkOption {
      type = lib.types.package;
      default = gh;
      readOnly = true;
      internal = true;
      description = "GitHub CLI with automatic App authentication.";
    };
    owner = lib.mkOption {
      type = lib.types.str;
      default = "kahlstrm";
      description = "Account whose repositories the App installation can access.";
    };
    bot = {
      login = lib.mkOption {
        type = lib.types.str;
        default = "kahlstrm-agents-pr-author[bot]";
        description = "App bot login used for commit attribution.";
      };
      userId = lib.mkOption {
        type = lib.types.strMatching "[0-9]+";
        default = "339864387";
        description = "App bot user ID for GitHub noreply commit attribution.";
      };
    };
    app = {
      id = lib.mkOption {
        type = lib.types.str;
        description = "GitHub App ID.";
      };
      installationId = lib.mkOption {
        type = lib.types.str;
        description = "Installation ID on the owner account.";
      };
      keyFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime PEM path; never a Nix store path.";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" cfg.app.keyFile && !(lib.hasPrefix "/nix/store/" cfg.app.keyFile);
        message = "agentGithub App key must be an absolute runtime path outside the Nix store";
      }
    ];
    environment.systemPackages = [
      helper
      (lib.hiPrio gh)
    ];
    environment.etc."agent-github.json".text = builtins.toJSON {
      inherit (cfg) owner app;
    };
    programs.git = {
      enable = true;
      config.credential = {
        helper = "${helper}/bin/git-credential-agent";
        useHttpPath = true;
      };
    };
  };
}
