{ lib, inputs, ... }:
let
  settings = import ./settings.nix;
  types = import ./types.nix { inherit lib; };
in
{
  imports = [
    inputs.microvm.nixosModules.host
    ./host.nix
    ./network.nix
  ];
  options.local.agentVMs = lib.mkOption {
    default = { };
    description = "Isolated T3 coding VMs; the attribute name is the MicroVM name.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            cores = lib.mkOption {
              type = lib.types.ints.positive;
            };
            memoryMiB = lib.mkOption {
              type = lib.types.ints.positive;
            };
            configuration = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Standalone flake configuration used to bootstrap the VM.";
            };
            unitPrefix = lib.mkOption {
              type = lib.types.strMatching "[a-z][a-z0-9-]*";
              default = "agent-${name}";
              description = "Prefix of the VM's host network units, nftables table, and tap network file.";
            };
            proxyHost = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            acmeHost = lib.mkOption {
              type = lib.types.str;
            };
            t3Port = lib.mkOption {
              type = lib.types.port;
              default = settings.t3Port;
            };
            network = {
              interface = lib.mkOption {
                type = lib.types.str;
                description = "Host tap interface; must match the guest's MicroVM tap interface.";
              };
              hostAddress = lib.mkOption {
                type = types.ipv4Address;
              };
              guestAddress = lib.mkOption {
                type = types.ipv4Address;
              };
              prefixLength = lib.mkOption {
                type = lib.types.ints.between 0 32;
              };
            };
            inherit (types) allowedServices;
          };
        }
      )
    );
  };
}
