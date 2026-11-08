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
  bambuddy = (import ./bambuddy-endpoint.nix).guest network;
  # Machines whose ops-deploy account (modules/ops-deploy.nix) ops reaches over SSH: the
  # address ops connects to (pannu at its gateway, zima on the LAN, poenttoe over ZeroTier,
  # since its public firewall closes SSH) and the lib/ssh-keys.nix host key name.
  deployTargets = {
    pannu = {
      address = network.hostAddress;
      hostKey = "p.kalski.xyz";
    };
    zima = {
      address = "10.1.1.30";
      hostKey = "zima.kalski.xyz";
    };
    poenttoe = {
      address = "10.255.255.3";
      hostKey = "poenttoe.kalski.xyz";
    };
  };
in
{
  inherit network deployTargets;
  inherit (cache) substituter substituterHosts;
  serviceHosts = bambuddy.hosts;
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
    # Bambuddy's API on pannu, on a port that serves only it and only to ops, for uploading
    # and slicing print files with an API key that cannot queue or control the printer.
    bambuddy = bambuddy.service;
  }
  // builtins.listToAttrs (
    map (name: {
      name = "${name}-ssh";
      value = {
        inherit (deployTargets.${name}) address;
        tcpPorts = [ 22 ];
      };
    }) (builtins.attrNames deployTargets)
  );
}
