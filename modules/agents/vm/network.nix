{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentNetworks;
  types = import ./types.nix { inherit lib; };
  serviceRules =
    net:
    lib.concatMapStringsSep "\n" (service: ''
      iifname "${net.interface}" ip daddr ${service.address} tcp dport { ${
        lib.concatMapStringsSep ", " toString service.tcpPorts
      } } accept
    '') (lib.attrValues net.allowedServices);
  # Each instance owns one table; its drops match only its own interface, so the
  # instances' tables compose and every guest is confined independently.
  rules =
    name: net:
    let
      table = "${lib.replaceStrings [ "-" ] [ "_" ] name}_guard";
    in
    pkgs.writeText "${name}-network.nft" ''
      table inet ${table};
      delete table inet ${table};
      table inet ${table} {
        set private4 {
          type ipv4_addr; flags interval;
          elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
            192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24,
            224.0.0.0/4, 240.0.0.0/4 };
        }
        chain guest_source {
          meta nfproto ipv6 drop
          ip saddr != ${net.guestAddress} counter drop
        }
        chain host_input {
          type filter hook input priority -100; policy accept;
          iifname "${net.interface}" jump guest_source
          iifname "${net.interface}" ct state established,related accept
          iifname "${net.interface}" ip daddr ${net.hostAddress} udp dport 53 accept
          iifname "${net.interface}" ip daddr ${net.hostAddress} tcp dport 53 accept
          iifname "${net.interface}" drop
        }
        chain forward {
          type filter hook forward priority -100; policy accept;
          iifname "${net.interface}" jump guest_source
          ${serviceRules net}
          iifname "${net.interface}" ip daddr @private4 drop
          iifname "${net.interface}" tcp dport { 80, 443 } accept
          iifname "${net.interface}" drop
          oifname "${net.interface}" ct state established,related accept
          oifname "${net.interface}" drop
        }
        chain nat {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${net.guestAddress} oifname != "${net.interface}" masquerade
        }
      }
    '';
  dnsService = name: net: {
    description = "Agent DNS forwarding through the host's current resolvers";
    wantedBy = [ "multi-user.target" ];
    after = [ "${name}-network.service" ];
    requires = [ "${name}-network.service" ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.dnsmasq}/bin/dnsmasq"
        "--keep-in-foreground"
        "--conf-file=/dev/null"
        "--pid-file="
        "--no-hosts"
        "--cache-size=0"
        "--bind-dynamic"
        "--listen-address=${net.hostAddress}"
        "--resolv-file=/etc/resolv.conf"
      ];
      DynamicUser = true;
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      Restart = "on-failure";
    };
  };
  networkService = name: net: {
    description = "Host-enforced agent VM network boundary";
    wantedBy = [ "multi-user.target" ];
    before = [ "microvm@${net.vm}.service" ];
    # The VM is PartOf this unit; reload rule changes instead of restarting it.
    reloadIfChanged = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nftables}/bin/nft -f ${rules name net}";
      ExecReload = "${pkgs.nftables}/bin/nft -f ${rules name net}";
    };
  };
  interfaces = lib.mapAttrsToList (_: net: net.interface) cfg;
in
{
  options.local.agentNetworks = lib.mkOption {
    default = { };
    description = ''
      Host-enforced egress isolation, one instance per agent VM. The attribute
      name prefixes the instance's units (`<name>-network`, `<name>-dns`) and
      nftables table (`<name>_guard`).
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          vm = lib.mkOption {
            type = lib.types.str;
            description = "MicroVM whose `microvm@` unit starts after this boundary.";
          };
          interface = lib.mkOption {
            type = lib.types.str;
          };
          guestAddress = lib.mkOption {
            type = types.ipv4Address;
          };
          hostAddress = lib.mkOption {
            type = types.ipv4Address;
            description = "VM-facing host address used for DNS forwarding.";
          };
          inherit (types) allowedServices;
        };
      }
    );
  };
  config = lib.mkIf (cfg != { }) {
    assertions = [
      {
        assertion = lib.allUnique interfaces;
        message = "local.agentNetworks instances must use distinct interfaces.";
      }
    ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    systemd.services = lib.mkMerge [
      (lib.mapAttrs' (name: net: lib.nameValuePair "${name}-dns" (dnsService name net)) cfg)
      (lib.mapAttrs' (name: net: lib.nameValuePair "${name}-network" (networkService name net)) cfg)
    ];
    networking.firewall.interfaces = lib.genAttrs interfaces (_: {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    });
    # Keep the host's existing iptables/Docker firewall; nft drops run first.
    networking.firewall.extraCommands = lib.concatMapStrings (interface: ''
      iptables -I FORWARD 1 -i ${interface} -j ACCEPT
      iptables -I FORWARD 1 -o ${interface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    '') interfaces;
    networking.firewall.extraStopCommands = lib.concatMapStrings (interface: ''
      iptables -D FORWARD -i ${interface} -j ACCEPT || true
      iptables -D FORWARD -o ${interface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
    '') interfaces;
  };
}
