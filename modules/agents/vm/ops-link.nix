# T3 links only over https or loopback, so the agents VM reaches ops' T3 through this loopback
# forward. Link from the agents VM with an ops pairing code limited to orchestration scopes:
#   on ops:    t3 pair --ttl 10m --scope orchestration:read --scope orchestration:operate
#   on agents: t3 environment link --access approval-required --pairing-code <code> http://127.0.0.1:3774
# Such a code refuses a full-access link, so the cap holds whoever redeems it. The traffic stays
# plain http on pannu's VM network, which only pannu can observe.
{ pkgs, ... }:
let
  ops = import ./ops-settings.nix;
in
{
  systemd.sockets.ops-t3-forward = {
    description = "Loopback forward to the ops VM's T3";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:3774" ];
  };
  systemd.services.ops-t3-forward = {
    description = "Forward loopback connections to the ops VM's T3";
    requires = [ "ops-t3-forward.socket" ];
    after = [ "ops-t3-forward.socket" ];
    serviceConfig = {
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${ops.network.guestAddress}:${toString ops.t3Port}";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_UNIX"
      ];
    };
  };
}
