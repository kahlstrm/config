{
  network = {
    interface = "agent-tap";
    hostAddress = "10.83.0.1";
    guestAddress = "10.83.0.2";
    prefixLength = 30;
    mac = "02:00:00:83:00:02";
  };
  t3Port = 3773;
  allowedServices.kubernetes-api = {
    address = "10.10.10.11";
    tcpPorts = [ 6443 ];
  };
}
