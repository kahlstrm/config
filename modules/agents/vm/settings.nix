{
  network = {
    interface = "agent-tap";
    hostAddress = "10.83.0.1";
    guestAddress = "10.83.0.2";
    prefixLength = 30;
    mac = "02:00:00:83:00:02";
  };
  t3Port = 3773;
  # The shared control-plane address behind kubernetesApiHostname.
  allowedServices.kubernetes-api = {
    address = "10.10.10.10";
    tcpPorts = [ 6443 ];
  };
  # The API server certificate covers this name, not the shared address.
  kubernetesApiHostname = "api.k8s.kalski.xyz";
}
