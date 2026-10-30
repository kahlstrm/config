{ pkgs }:
let
  # A VM stand-in bound to its boundary like microvm@<name>, which must survive rule changes.
  standIn = boundary: {
    wantedBy = [ "multi-user.target" ];
    requires = [ "${boundary}.service" ];
    after = [ "${boundary}.service" ];
    partOf = [ "${boundary}.service" ];
    serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
  };
  mkGuest =
    {
      vlan,
      address,
      gateway,
    }:
    {
      virtualisation.vlans = [ vlan ];
      networking.interfaces.eth1 = {
        ipv4.addresses = [
          {
            inherit address;
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
      networking.defaultGateway = gateway;
      networking.nameservers = [ gateway ];
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
in
pkgs.testers.runNixOSTest {
  name = "agent-network";
  nodes = {
    host = {
      imports = [ ../modules/agents/vm/network.nix ];
      local.agentNetworks.agent = {
        vm = "agents";
        interface = "eth1";
        hostAddress = "10.83.0.1";
        guestAddress = "10.83.0.2";
        allowedServices.kubernetes-api = {
          address = "192.168.7.2";
          tcpPorts = [ 6443 ];
        };
      };
      # A second instance on its own tap and /30, without allowed services.
      local.agentNetworks.agent-ops = {
        vm = "ops";
        interface = "eth3";
        hostAddress = "10.83.0.5";
        guestAddress = "10.83.0.6";
      };
      networking.nameservers = [ "192.168.7.2" ];
      # A DHCP lease on QEMU's user network would add a resolver that cannot answer home.test.
      networking.useDHCP = false;
      networking.defaultGateway = {
        address = "8.8.8.2";
        interface = "eth2";
      };
      virtualisation.vlans = [
        1
        2
        3
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
      networking.interfaces.eth3.ipv4.addresses = [
        {
          address = "10.83.0.5";
          prefixLength = 30;
        }
      ];
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
      systemd.services.vm-stand-in = standIn "agent-network";
      systemd.services.ops-stand-in = standIn "agent-ops-network";
      specialisation.moved-api.configuration.local.agentNetworks.agent.allowedServices.kubernetes-api.address =
        pkgs.lib.mkForce "192.168.7.3";
    };
    guest = mkGuest {
      vlan = 1;
      address = "10.83.0.2";
      gateway = "10.83.0.1";
    };
    ops = mkGuest {
      vlan = 3;
      address = "10.83.0.6";
      gateway = "10.83.0.5";
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
    host.wait_for_unit("agent-ops-network.service")
    guest.wait_for_unit("browser.service")
    ops.wait_for_unit("browser.service")
    internet.wait_for_unit("nginx.service")
    internet.wait_for_unit("api.service")
    internet.wait_for_unit("dnsmasq.service")
    guest.wait_until_succeeds("dig +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
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
    # A second instance is confined to its own forwarder and services, and the two cannot reach each other.
    ops.wait_until_succeeds("dig +short +time=2 +tries=1 @10.83.0.5 api.home.test | grep -x 192.168.7.2")
    ops.succeed("curl --fail --max-time 5 http://8.8.8.2 | grep public-web")
    host.succeed("curl --fail --max-time 5 http://10.83.0.6:3773/")
    ops.fail("curl --max-time 2 http://192.168.7.2:6443/")
    for target in ["10.83.0.1", "10.83.0.1:3773", "10.83.0.2:3773"]:
        ops.fail(f"curl --max-time 2 http://{target}")
    for target in ["10.83.0.5", "10.83.0.5:3773", "10.83.0.6:3773"]:
        guest.fail(f"curl --max-time 2 http://{target}")
    ops.fail("dig +short +time=1 +tries=1 @10.83.0.1 api.home.test")
    ops.fail("dig +tcp +short +time=1 +tries=1 @10.83.0.1 api.home.test")
    guest.fail("dig +short +time=1 +tries=1 @10.83.0.5 api.home.test")
    guest.fail("dig +tcp +short +time=1 +tries=1 @10.83.0.5 api.home.test")
    # Each guest is also refused the other instance's guest address as its source.
    guest.succeed("ip address add 10.83.0.6/32 dev eth1")
    guest.fail("curl --interface 10.83.0.6 --max-time 2 http://8.8.8.2")
    guest.fail("curl --interface 10.83.0.6 --max-time 2 http://192.168.7.2:6443/")
    guest.fail("dig -b 10.83.0.6 +time=1 +tries=1 @10.83.0.1 api.home.test")
    ops.succeed("ip address add 10.83.0.2/32 dev eth1")
    ops.fail("curl --interface 10.83.0.2 --max-time 2 http://8.8.8.2")
    for table in ["agent_guard", "agent_ops_guard"]:
        host.succeed(f"nft list chain inet {table} guest_source | grep -E 'ip saddr != .* counter packets [1-9]'")
    internet.fail("curl --max-time 2 http://10.83.0.2:3773")
    host.succeed("systemctl reload agent-network")
    host.succeed("systemctl restart firewall")
    guest.wait_until_succeeds("curl --fail --max-time 5 http://8.8.8.2")
    guest.succeed("curl --fail --max-time 5 http://192.168.7.2:6443/")
    guest.fail("curl --max-time 2 http://192.168.7.3:6443/")
    guest.fail("curl --max-time 2 http://192.168.7.2:80/")
    guest.wait_until_succeeds("dig +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
    guest.succeed("dig +tcp +short +time=2 +tries=1 @10.83.0.1 api.home.test | grep -x 192.168.7.2")
    internet.wait_for_unit("alternate-dns.service")
    host.succeed("printf 'nameserver 192.168.7.3\\n' > /etc/resolv.conf")
    guest.wait_until_succeeds("dig +short +time=2 +tries=1 @10.83.0.1 alternate.home.test | grep -x 192.168.7.3")
    guest.succeed("dig +tcp +short +time=2 +tries=1 @10.83.0.1 alternate.home.test | grep -x 192.168.7.3")
    guest.fail("curl --max-time 2 http://10.83.0.1")
    # Changing the allowed services reloads the rules without restarting the VM.
    stand_ins = ["vm-stand-in", "ops-stand-in"]
    for unit in stand_ins:
        host.wait_for_unit(f"{unit}.service")
    invocations = {unit: host.succeed(f"systemctl show -P InvocationID {unit}") for unit in stand_ins}
    host.succeed("/run/current-system/specialisation/moved-api/bin/switch-to-configuration test")
    guest.wait_until_succeeds("curl --fail --max-time 5 http://192.168.7.3:6443/")
    guest.fail("curl --max-time 2 http://192.168.7.2:6443/")
    for unit, invocation in invocations.items():
        assert host.succeed(f"systemctl show -P InvocationID {unit}") == invocation, f"{unit} restarted"
  '';
}
