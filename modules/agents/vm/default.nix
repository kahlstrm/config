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
    proxyHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    acmeHost = lib.mkOption {
      type = lib.types.str;
    };
    configuration = lib.mkOption {
      type = lib.types.str;
      default = "agents";
      description = "Standalone flake configuration used to bootstrap the agent VM.";
    };
  };
}
