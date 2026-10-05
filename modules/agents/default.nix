{ lib, inputs, ... }:
{
  imports = [
    inputs.microvm.nixosModules.host
    ./host.nix
    ./network.nix
    (lib.mkAliasOptionModule
      [ "local" "agents" "allowedServices" ]
      [ "local" "agentNetwork" "allowedServices" ]
    )
  ];
  options.local.agents = {
    enable = lib.mkEnableOption "isolated T3 coding VM";
    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
    };
    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    proxyHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    acmeHost = lib.mkOption {
      type = lib.types.str;
      default = "p.kalski.xyz";
    };
    guestModule = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = "Additional declarative guest settings, including App IDs and age secrets.";
    };
  };
}
