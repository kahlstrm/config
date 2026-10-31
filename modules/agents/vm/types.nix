{ lib }:
rec {
  ipv4Address = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
  allowedServices = lib.mkOption {
    default = { };
    description = "Named exceptions for routed IPv4 services; host access remains blocked.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = ipv4Address;
            description = "Exact destination IPv4 address.";
          };
          tcpPorts = lib.mkOption {
            type = lib.types.nonEmptyListOf lib.types.port;
          };
        };
      }
    );
  };
}
