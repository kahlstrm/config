{ lib }:
rec {
  ipv4Address = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
  endpoint =
    addressDescription:
    lib.types.submodule {
      options = {
        address = lib.mkOption {
          type = ipv4Address;
          description = addressDescription;
        };
        tcpPorts = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.port;
        };
      };
    };
  allowedServices = lib.mkOption {
    default = { };
    description = "Named exceptions for routed IPv4 services; host access remains blocked.";
    type = lib.types.attrsOf (endpoint "Exact destination IPv4 address.");
  };
}
