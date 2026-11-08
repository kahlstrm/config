# The ops VM: holds root infrastructure credentials; the agents VM reaches its T3 only.
let
  agents = import ./settings.nix;
  talosApi = address: {
    inherit address;
    tcpPorts = [ 50000 ];
  };
  network = {
    interface = "ops-tap";
    hostAddress = "10.83.0.5";
    guestAddress = "10.83.0.6";
    prefixLength = 30;
    mac = "02:00:00:83:00:06";
  };
  cache = (import ./cache-endpoint.nix).guest network;
in
{
  inherit network;
  inherit (cache) substituter substituterHosts;
  inherit (agents) t3Port;
  allowedServices = {
    # Ops deploys download what the host built instead of building T3 Code in 4 GiB.
    nix-cache = cache.service;
    inherit (agents.allowedServices)
      kubernetes-api
      talos-api-c1
      talos-api-c2
      talos-api-c3
      ;
    # Terraform's Talos provider and admin talosctl reach every node's apid directly.
    talos-api-w1 = talosApi "10.10.10.21";
    talos-api-w2 = talosApi "10.10.10.22";
    # Traefik's LoadBalancer (MetalLB's first private-pool address), for maintenance checks
    # of the ingress path over HTTPS: the *.kube.kalski.xyz apps and Harbor.
    traefik-lb = {
      address = "10.10.10.80";
      tcpPorts = [ 443 ];
    };
    # kuberack's RouterOS REST API, where ops' `ops` user may only read and run the PoE
    # power-cycle scripts that infra/local-networking declares for the Pi control planes.
    kuberack-rest = {
      address = "10.10.10.1";
      tcpPorts = [ 443 ];
    };
  };
}
