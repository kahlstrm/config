{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentNetwork;
  defaults = (import ./settings.nix).network;
  ipv4Address = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
  serviceRules = lib.concatMapStringsSep "\n" (service: ''
    iifname "${cfg.interface}" ip daddr ${service.address} tcp dport { ${
      lib.concatMapStringsSep ", " toString service.tcpPorts
    } } accept
  '') (lib.attrValues cfg.allowedServices);
  rules = pkgs.writeText "agent-network.nft" ''
    table inet agent_guard;
    delete table inet agent_guard;
    table inet agent_guard {
      set private4 {
        type ipv4_addr; flags interval;
        elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
          169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
          192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24,
          224.0.0.0/4, 240.0.0.0/4 };
      }
      chain guest_source {
        meta nfproto ipv6 drop
        ip saddr != ${cfg.guestAddress} counter drop
      }
      chain host_input {
        type filter hook input priority -100; policy accept;
        iifname "${cfg.interface}" jump guest_source
        iifname "${cfg.interface}" ct state established,related accept
        iifname "${cfg.interface}" ip daddr ${cfg.hostAddress} udp dport 53 accept
        iifname "${cfg.interface}" ip daddr ${cfg.hostAddress} tcp dport 53 accept
        iifname "${cfg.interface}" drop
      }
      chain forward {
        type filter hook forward priority -100; policy accept;
        iifname "${cfg.interface}" jump guest_source
        ${serviceRules}
        iifname "${cfg.interface}" ip daddr @private4 drop
        iifname "${cfg.interface}" tcp dport { 80, 443 } accept
        iifname "${cfg.interface}" drop
        oifname "${cfg.interface}" ct state established,related accept
        oifname "${cfg.interface}" drop
      }
      chain nat {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${cfg.guestAddress} oifname != "${cfg.interface}" masquerade
      }
    }
  '';
in
{
  options.local.agentNetwork = {
    enable = lib.mkEnableOption "host-enforced agent egress isolation";
    interface = lib.mkOption {
      type = lib.types.str;
      default = defaults.interface;
    };
    guestAddress = lib.mkOption {
      type = lib.types.str;
      default = defaults.guestAddress;
    };
    hostAddress = lib.mkOption {
      type = ipv4Address;
      default = defaults.hostAddress;
      description = "VM-facing host address used for DNS forwarding.";
    };
    allowedServices = lib.mkOption {
      default = { };
      description = "Named exceptions for routed IPv4 services; host access remains blocked.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = ipv4Address;
              description = "Exact destination IPv4 address.";
            };
            tcpPorts = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.port;
            };
          };
        }
      );
    };
  };
  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    systemd.services.agent-dns = {
      description = "Agent DNS forwarding through the host's current resolvers";
      wantedBy = [ "multi-user.target" ];
      after = [ "agent-network.service" ];
      requires = [ "agent-network.service" ];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.dnsmasq}/bin/dnsmasq"
          "--keep-in-foreground"
          "--conf-file=/dev/null"
          "--pid-file="
          "--no-hosts"
          "--cache-size=0"
          "--bind-dynamic"
          "--listen-address=${cfg.hostAddress}"
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
    networking.firewall.interfaces.${cfg.interface} = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
    systemd.services.agent-network = {
      description = "Host-enforced agent VM network boundary";
      wantedBy = [ "multi-user.target" ];
      before = [ "microvm@agents.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
        ExecReload = "${pkgs.nftables}/bin/nft -f ${rules}";
      };
    };
    # Keep the host's existing iptables/Docker firewall; nft drops run first.
    networking.firewall.extraCommands = ''
      iptables -I FORWARD 1 -i ${cfg.interface} -j ACCEPT
      iptables -I FORWARD 1 -o ${cfg.interface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D FORWARD -i ${cfg.interface} -j ACCEPT || true
      iptables -D FORWARD -o ${cfg.interface} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
    '';
  };
}
