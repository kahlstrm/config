rec {
  # Covered by the host's *.p.kalski.xyz certificate; each guest resolves it to its own gateway.
  name = "nix-cache.p.kalski.xyz";
  # Only the cache listens on this port, so no other virtual host answers the guests.
  port = 5443;
  # The host's binary cache as one guest reaches it: on the guest's own gateway address.
  # Only the host can answer there, and it already controls the guest, so the guest
  # trusts the cache's unsigned paths; TLS authenticates the host as well.
  guest = network: {
    substituter = "https://${name}:${toString port}?trusted=true";
    substituterHosts.${network.hostAddress} = [ name ];
    service = {
      address = network.hostAddress;
      tcpPorts = [ port ];
    };
  };
}
