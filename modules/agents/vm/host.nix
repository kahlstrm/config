{
  config,
  lib,
  inputs,
  ...
}:
let
  cfg = config.local.agents;
  settings = import ./settings.nix;
  network = settings.network;
in
{
  config = lib.mkIf cfg.enable {
    local.agentNetwork.enable = true;
    networking.networkmanager.unmanaged = [ "interface-name:${network.interface}" ];
    systemd.network.enable = true;
    systemd.network.networks."10-agent-tap" = {
      matchConfig.Name = network.interface;
      address = [ "${network.hostAddress}/${toString network.prefixLength}" ];
      networkConfig = {
        DHCP = "no";
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
      };
    };
    microvm.vms.agents = {
      evaluatedConfig = inputs.self.nixosConfigurations.${cfg.configuration}.extendModules {
        modules = [
          {
            microvm.vcpu = lib.mkForce cfg.cores;
            microvm.mem = lib.mkForce cfg.memoryMiB;
          }
        ];
      };
    };
    systemd.services."microvm@agents" = {
      requires = [ "agent-network.service" ];
      after = [ "agent-network.service" ];
      partOf = [ "agent-network.service" ];
      serviceConfig = {
        CPUQuota = "${toString (cfg.cores * 100)}%";
        MemoryMax = "${toString (cfg.memoryMiB + 2048)}M";
        TasksMax = 512;
      };
    };
    services.nginx.virtualHosts = lib.mkIf (cfg.proxyHost != null) {
      ${cfg.proxyHost} = {
        forceSSL = true;
        useACMEHost = cfg.acmeHost;
        locations."/" = {
          proxyPass = "http://${network.guestAddress}:${toString settings.t3Port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
          '';
        };
      };
    };
  };
}
