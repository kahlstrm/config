{
  config,
  lib,
  pkgs,
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
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "agents requires an SSH administrator public key";
      }
    ];
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
      pkgs = import inputs.nixpkgs-unstable-nixos {
        system = pkgs.stdenv.hostPlatform.system;
        config.allowUnfree = true;
        overlays = [ inputs.microvm.overlays.default ];
      };
      config = {
        imports = [
          ./guest.nix
          ../agent-github
          inputs.agenix.nixosModules.default
          cfg.guestModule
        ];
        local.agentVm = {
          inherit settings;
          inherit (cfg) authorizedKeys;
          revision = inputs.self.rev or "dirty";
          networkServices = config.local.agentNetwork.allowedServices;
        };
        networking.nameservers = [ config.local.agentNetwork.hostAddress ];
        microvm = {
          hypervisor = "qemu";
          vcpu = cfg.cores;
          mem = cfg.memoryMiB;
          shares = [ ];
          storeOnDisk = true;
          writableStoreOverlay = "/nix/.rw-store";
          interfaces = [
            {
              type = "tap";
              id = network.interface;
              mac = network.mac;
            }
          ];
          volumes = [
            {
              image = "home.img";
              mountPoint = "/home";
              size = 40960;
            }
            {
              image = "var.img";
              mountPoint = "/var";
              size = 8192;
            }
            {
              image = "nix.img";
              mountPoint = "/nix";
              size = 16384;
            }
          ];
        };
        fileSystems."/nix".neededForBoot = true;
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
