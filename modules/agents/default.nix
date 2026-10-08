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
    };
    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
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
    };
    guestModule = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = "Additional declarative guest settings, including App IDs and age secrets.";
    };
  };
}
