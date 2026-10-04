{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentGithub;
  app = lib.types.submodule {
    options = {
      id = lib.mkOption {
        type = lib.types.str;
        description = "GitHub App ID.";
      };
      installationId = lib.mkOption {
        type = lib.types.str;
        description = "Installation ID for the owning account.";
      };
      keyFile = lib.mkOption {
        type = lib.types.str;
        description = "Runtime PEM path; never a Nix store path.";
      };
    };
  };
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
    text = ''exec ${credentials}/bin/agent-credentials gh-auto ${pkgs.gh}/bin/gh "$@"'';
  };
  ghAgent = pkgs.writeShellApplication {
    name = "gh-agent";
    runtimeInputs = [
      pkgs.git
    ];
    text = ''exec ${credentials}/bin/agent-credentials gh ${pkgs.gh}/bin/gh "$@"'';
  };
in
{
  options.local.agentGithub = {
    enable = lib.mkEnableOption "separate GitHub fork and PR App credentials";
    package = lib.mkOption {
      type = lib.types.package;
      default = gh;
      readOnly = true;
      internal = true;
      description = "GitHub CLI with automatic App authentication.";
    };
    forkOwner = lib.mkOption {
      type = lib.types.str;
      default = "kqlski";
    };
    upstreamOwner = lib.mkOption {
      type = lib.types.str;
      default = "kahlstrm";
    };
    repositories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "config" ];
    };
    apps = {
      fork = lib.mkOption { type = app; };
      upstream = lib.mkOption { type = app; };
    };
  };
  config = lib.mkIf cfg.enable {
    assertions =
      map
        (name: {
          assertion =
            lib.hasPrefix "/" cfg.apps.${name}.keyFile
            && !(lib.hasPrefix "/nix/store/" cfg.apps.${name}.keyFile);
          message = "agentGithub ${name} key must be an absolute runtime path outside the Nix store";
        })
        [
          "fork"
          "upstream"
        ];
    environment.systemPackages = [
      helper
      (lib.hiPrio gh)
      ghAgent
    ];
    environment.etc."agent-github.json".text = builtins.toJSON {
      inherit (cfg)
        forkOwner
        upstreamOwner
        repositories
        apps
        ;
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
