# The ops VM: holds root infrastructure credentials; the agents VM reaches its T3 only.
let
  agents = import ./settings.nix;
  talosApi = address: {
    inherit address;
    tcpPorts = [ 50000 ];
  };
in
{
  network = {
    interface = "ops-tap";
    hostAddress = "10.83.0.5";
    guestAddress = "10.83.0.6";
    prefixLength = 30;
    mac = "02:00:00:83:00:06";
  };
  inherit (agents) t3Port;
  allowedServices = {
    inherit (agents.allowedServices)
      kubernetes-api
      talos-api-c1
      talos-api-c2
      talos-api-c3
      ;
    # Terraform's Talos provider and admin talosctl reach every node's apid directly.
    talos-api-w1 = talosApi "10.10.10.21";
    talos-api-w2 = talosApi "10.10.10.22";
  };
}
