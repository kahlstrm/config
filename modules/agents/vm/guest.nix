{ config, lib, ... }:
let
  settings = import ./settings.nix;
  inherit (settings) network;
in
{
  options.local.agentVM.diskDirectory = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "Host directory for persistent disk images; null uses the MicroVM state directory.";
  };
  config = {
    networking = {
      hostName = "agents";
      useNetworkd = true;
      useDHCP = false;
      enableIPv6 = false;
      nameservers = [ network.hostAddress ];
    };
    systemd.network.networks."10-agent" = {
      matchConfig.MACAddress = network.mac;
      address = [ "${network.guestAddress}/${toString network.prefixLength}" ];
      routes = [ { Gateway = network.hostAddress; } ];
      networkConfig.IPv6AcceptRA = false;
    };
    local.agentEnvironment = {
      deploy.hostCompatibility = {
        inherit settings;
        inherit (config.local.agentEnvironment) bindAddress t3Port;
        inherit (config.networking) nameservers;
        network = {
          inherit (config.systemd.network.networks."10-agent")
            matchConfig
            address
            routes
            networkConfig
            ;
        };
        interfaces = map (interface: { inherit (interface) type id mac; }) config.microvm.interfaces;
        volumes = map (volume: {
          inherit (volume)
            image
            serial
            mountPoint
            size
            ;
        }) config.microvm.volumes;
        shares = map (share: {
          inherit (share)
            source
            mountPoint
            proto
            tag
            ;
        }) config.microvm.shares;
        inherit (config.microvm) storeOnDisk writableStoreOverlay;
        fileSystems = lib.genAttrs [ "/home" "/var" "/nix" ] (mountPoint: {
          inherit (config.fileSystems.${mountPoint})
            device
            fsType
            options
            neededForBoot
            ;
        });
      };
      bindAddress = network.guestAddress;
      inherit (settings) t3Port;
      isolation = {
        mode = "VM";
        hostShares = [ ];
        egress = "public HTTP/HTTPS and configured DNS; private destinations otherwise blocked except allowedServices";
        dnsServers = config.networking.nameservers;
        allowedServices = settings.allowedServices;
        deployment = "merged upstream main; guest userspace only";
      };
      resources = {
        vcpus = config.microvm.vcpu;
        memoryMiB = config.microvm.mem;
        disks = map (volume: { inherit (volume) mountPoint size; }) config.microvm.volumes;
      };
    };
    microvm = {
      hypervisor = "qemu";
      vcpu = lib.mkDefault 8;
      mem = lib.mkDefault 32768;
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
      volumes =
        map
          (volume: {
            image =
              lib.optionalString (
                config.local.agentVM.diskDirectory != null
              ) "${config.local.agentVM.diskDirectory}/"
              + "${volume.name}.img";
            serial = "agents-${volume.name}";
            mountPoint = "/${volume.name}";
            inherit (volume) size;
          })
          [
            {
              name = "home";
              size = 40960;
            }
            {
              name = "var";
              size = 8192;
            }
            {
              name = "nix";
              size = 16384;
            }
          ];
    };
    # Stable virtio identities also make /nix available during stage 2.
    fileSystems = lib.genAttrs [ "/home" "/var" "/nix" ] (mountPoint: {
      device = lib.mkForce "/dev/disk/by-id/virtio-agents-${builtins.baseNameOf mountPoint}";
      neededForBoot = mountPoint == "/nix";
    });
  };
}
