{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "agent-network";
  nodes = {
    host = {
      imports = [ ../modules/agents/vm/network.nix ];
      local.agentNetwork = {
        enable = true;
        interface = "eth1";
        allowedServices.kubernetes-api = {
          address = "192.168.7.2";
          tcpPorts = [ 6443 ];
        };
      };
      networking.nameservers = [ "192.168.7.2" ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.interfaces.eth1 = {
        ipv4.addresses = [
          {
            address = "10.83.0.1";
            prefixLength = 30;
          }
        ];
        ipv6.addresses = [
          {
            address = "fd00::1";
            prefixLength = 64;
          }
        ];
      };
      networking.interfaces.eth2.ipv4.addresses = [
        {
          address = "8.8.8.1";
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth2.ipv4.routes = [
        {
          address = "192.168.7.0";
          prefixLength = 24;
          via = "8.8.8.2";
        }
        {
          address = "100.64.7.0";
          prefixLength = 24;
          via = "8.8.8.2";
        }
      ];
      services.nginx = {
        enable = true;
        virtualHosts.default.locations."/".proxyPass = "http://10.83.0.2:3773";
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.nftables
      ];
    };
    guest = {
      virtualisation.vlans = [ 1 ];
      networking.interfaces.eth1 = {
        ipv4.addresses = [
          {
            address = "10.83.0.2";
            prefixLength = 30;
          }
        ];
        ipv6.addresses = [
          {
            address = "fd00::2";
            prefixLength = 64;
          }
        ];
      };
      networking.defaultGateway = "10.83.0.1";
      networking.nameservers = [ "10.83.0.1" ];
      networking.firewall.allowedTCPPorts = [ 3773 ];
      systemd.services.browser = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 3773 --bind 0.0.0.0";
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.netcat-openbsd
        pkgs.dig
      ];
    };
    internet = {
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = [
        {
          address = "8.8.8.2";
          prefixLength = 24;
        }
        {
          address = "192.168.7.2";
          prefixLength = 24;
        }
        {
          address = "192.168.7.3";
          prefixLength = 24;
        }
        {
          address = "100.64.7.2";
          prefixLength = 24;
        }
      ];
      networking.defaultGateway = "8.8.8.1";
      services.nginx = {
        enable = true;
        virtualHosts.default.locations."/".return = "200 public-web";
      };
      services.openssh.enable = true;
      services.dnsmasq = {
        enable = true;
        settings = {
          no-resolv = true;
          listen-address = "192.168.7.2";
          bind-interfaces = true;
          host-record = "api.home.test,192.168.7.2";
        };
      };
      systemd.services.alternate-dns = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --pid-file= --no-resolv --bind-dynamic --listen-address=192.168.7.3 --host-record=alternate.home.test,192.168.7.3";
      };
      systemd.services.api = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 6443 --bind 0.0.0.0";
      };
      networking.firewall.allowedTCPPorts = [
        80
        6443
        53
      ];
      networking.firewall.allowedUDPPorts = [ 53 ];
    };
  };
  testScript = ''
    start_all()
    host.wait_for_unit("agent-network.service")
    guest.wait_for_unit("browser.service")
    internet.wait_for_unit("nginx.service")
    internet.wait_for_unit("api.service")
    internet.wait_for_unit("dnsmasq.service")
    guest.succeed("dig +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
    guest.succeed("dig +tcp +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
    guest.fail("dig +short +time=1 +tries=1 @192.168.7.2 api.home.test")
    internet.fail("dig +short +time=1 +tries=1 @8.8.8.1 api.home.test")
    guest.succeed("curl --fail --max-time 5 http://api.home.test:6443/")
    guest.fail("curl --max-time 2 http://api.home.test:80/")
    guest.fail("dig +short +time=1 +tries=1 @192.168.7.3 api.home.test")
    guest.fail("dig +tcp +short +time=1 +tries=1 @192.168.7.3 api.home.test")
    guest.succeed("curl --fail --max-time 5 http://8.8.8.2 | grep public-web")
    guest.succeed("curl --fail --max-time 5 http://192.168.7.2:6443/")
    guest.fail("curl --max-time 2 http://192.168.7.3:6443/")
    # Response traffic from the guest can reach a host-initiated reverse proxy.
    host.succeed("curl --fail --max-time 5 http://127.0.0.1/")
    for target in ["10.83.0.1", "192.168.7.2", "100.64.7.2"]:
        guest.fail(f"curl --fail --max-time 2 http://{target}")
    guest.fail("nc -z -w 2 8.8.8.2 22")
    guest.fail("nc -6 -z -w 2 fd00::1 80")
    guest.succeed("ip address add 10.83.0.6/32 dev eth1")
    guest.fail("curl --interface 10.83.0.6 --max-time 2 http://8.8.8.2")
    guest.fail("curl --interface 10.83.0.6 --max-time 2 http://192.168.7.2:6443/")
    guest.fail("dig -b 10.83.0.6 +time=1 +tries=1 @10.83.0.1 api.home.test")
    host.succeed("nft list chain inet agent_guard guest_source | grep -E 'ip saddr != .* counter packets [1-9]'")
    internet.fail("curl --max-time 2 http://10.83.0.2:3773")
    host.succeed("systemctl reload agent-network")
    host.succeed("systemctl restart firewall")
    guest.succeed("curl --fail --max-time 5 http://8.8.8.2")
    guest.succeed("curl --fail --max-time 5 http://192.168.7.2:6443/")
    guest.fail("curl --max-time 2 http://192.168.7.3:6443/")
    guest.fail("curl --max-time 2 http://192.168.7.2:80/")
    guest.succeed("dig +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
    guest.succeed("dig +tcp +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
    internet.wait_for_unit("alternate-dns.service")
    host.succeed("printf 'nameserver 192.168.7.3\\n' > /etc/resolv.conf")
    guest.wait_until_succeeds("dig +short +time=2 +tries=1 @10.83.0.1 alternate.home.test | grep -x 192.168.7.3")
    guest.succeed("dig +tcp +short +time=2 +tries=1 @10.83.0.1 alternate.home.test | grep -x 192.168.7.3")
    guest.fail("curl --max-time 2 http://10.83.0.1")
  '';
}
