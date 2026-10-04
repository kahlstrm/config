{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.local.agentHost;
in
{
  imports = [
    inputs.microvm.nixosModules.host
    ./network.nix
  ];
  options.local.agentHost = {
    enable = lib.mkEnableOption "isolated T3 coding VM";
    cores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
    };
    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
    };
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    proxyHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    acmeHost = lib.mkOption {
      type = lib.types.str;
      default = "p.kalski.xyz";
    };
    guestModule = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = "Additional declarative guest settings, including App IDs and age secrets.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "agentHost requires an SSH administrator public key";
      }
    ];
    local.agentNetwork.enable = true;
    networking.networkmanager.unmanaged = [ "interface-name:agent-tap" ];
    systemd.network.enable = true;
    systemd.network.networks."10-agent-tap" = {
      matchConfig.Name = "agent-tap";
      address = [ "10.83.0.1/30" ];
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
          ../agent-vm
          ../agent-github
          inputs.agenix.nixosModules.default
          cfg.guestModule
        ];
        local.agentVm = {
          inherit (cfg) authorizedKeys;
          revision = inputs.self.rev or "dirty";
          networkServices = config.local.agentNetwork.allowedServices;
        };
        networking.nameservers = config.local.agentNetwork.dnsServers;
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
              id = "agent-tap";
              mac = "02:00:00:83:00:02";
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
          proxyPass = "http://10.83.0.2:3773";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 3600s;
          '';
        };
      };
    };
  };
}
