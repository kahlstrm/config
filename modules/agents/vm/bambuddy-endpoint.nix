rec {
  # Bambuddy on pannu, covered by the host's *.p.kalski.xyz certificate; ops resolves the
  # name to its own gateway.
  name = "bambuddy.p.kalski.xyz";
  # Only Bambuddy listens on this port, and only for ops, so no other virtual host answers.
  port = 8443;
  guest = network: {
    hosts.${network.hostAddress} = [ name ];
    service = {
      address = network.hostAddress;
      tcpPorts = [ port ];
    };
  };
}
