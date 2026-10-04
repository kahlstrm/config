{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.agentNetwork;
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
        iifname "${cfg.interface}" drop
      }
      chain forward {
        type filter hook forward priority -100; policy accept;
        iifname "${cfg.interface}" jump guest_source
        iifname "${cfg.interface}" ip daddr @private4 drop
        iifname "${cfg.interface}" tcp dport { 80, 443 } accept
        iifname "${cfg.interface}" ip daddr { 9.9.9.9, 149.112.112.112 } udp dport 53 accept
        iifname "${cfg.interface}" ip daddr { 9.9.9.9, 149.112.112.112 } tcp dport 53 accept
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
      default = "agent-tap";
    };
    guestAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.83.0.2";
    };
  };
  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
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
