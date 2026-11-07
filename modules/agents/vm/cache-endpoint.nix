rec {
  port = 5000;
  # The host's binary cache as one guest reaches it: on the guest's own gateway address.
  # Only the host can answer there, and it already controls the guest, so the guest
  # trusts the cache's paths without a signing key.
  guest = network: {
    substituter = "http://${network.hostAddress}:${toString port}?trusted=true";
    service = {
      address = network.hostAddress;
      tcpPorts = [ port ];
    };
  };
}
