{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentEnvironment.deploy;
in
{
  options.local.agentEnvironment.deploy = {
    enable = lib.mkEnableOption "deployment of merged upstream main inside the agent environment";
    repository = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
      default = "kahlstrm/config";
    };
    configuration = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      description = "Fixed nixosConfigurations target; callers cannot override it.";
    };
    bootMode = lib.mkOption {
      type = lib.types.enum [
        "host"
        "system"
      ];
      default = "system";
      description = "Host-provided VM boot image or native NixOS bootloader.";
    };
    hostCompatibility = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      internal = true;
      description = "Host-coupled configuration that must match the VM boot image.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      default = pkgs.callPackage ./deploy-package.nix {
        inherit (cfg) repository configuration bootMode;
        nix = config.nix.package;
        platform = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "nixos";
        # The deploy test imports this module without the full agent environment.
        user = config.local.agentEnvironment.user or "agent";
      };
    };
  };
}
