{ config, lib, ... }:
let
  cfg = config.local.agentVM;
  inherit (cfg) settings;
  inherit (settings) network;
in
{
  imports = [
    ./store.nix
    ./sudo.nix
  ];
  options.local.agentVM = {
    name = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]*";
      description = "Instance name: the guest host name and the prefix of its disks' virtio serials.";
    };
    settings = lib.mkOption {
      type = lib.types.attrs;
      description = ''
        Settings the host shares with this guest: `network` (interface, hostAddress,
        guestAddress, prefixLength, mac), `t3Port`, `allowedServices` and optionally
        `substituter`, the host's binary cache, with `substituterHosts` resolving its name.
      '';
    };
    volumeSizes = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = {
        home = 200 * 1024;
        var = 8 * 1024;
        nix = 32 * 1024;
      };
      description = "Persistent volume sizes in MiB for /home, /var and /nix.";
    };
    diskDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host directory for persistent disk images; null uses the MicroVM state directory.";
    };
  };
  config = {
    networking = {
      hostName = cfg.name;
      useNetworkd = true;
      useDHCP = false;
      enableIPv6 = false;
      nameservers = [ network.hostAddress ];
    };
    # The host serves the systems it builds; guests prefer it to rebuilding them.
    nix.settings.substituters = lib.optional (settings ? substituter) settings.substituter;
    networking.hosts = settings.substituterHosts or { };
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
        fileSystems = lib.genAttrs [ "/home" "/var" "/nix" "/nix/store" "/nix/.ro-store" ] (mountPoint: {
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
      # On QEMU's microvm machine, virtio-mmio completion interrupts are sometimes lost under
      # sustained writes: the used ring holds every completion, but the guest waits on full
      # request tags forever. virtio-pci on q35 signals through MSI-X instead.
      qemu.machine = "q35";
      vcpu = lib.mkDefault 8;
      mem = lib.mkDefault 32768;
      shares = [ ];
      storeOnDisk = true;
      writableStoreOverlay = null;
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
            serial = "${cfg.name}-${volume.name}";
            mountPoint = "/${volume.name}";
            # preStart creates missing images; microvm.nix would only create them after it, sparse.
            autoCreate = false;
            inherit (volume) size;
          })
          (
            map
              (name: {
                inherit name;
                size = cfg.volumeSizes.${name};
              })
              [
                "home"
                "var"
                "nix"
              ]
          );
    };
    # Create missing images, grow existing ones to their configured size, and
    # reserve it, so the VM cannot overcommit the host's disk. mke2fs discards,
    # which punches holes in an image file, so the reservation runs after it.
    # Shrinking an image is a manual, offline resize; an oversized image, or a
    # host without the space, gets a warning instead of keeping the VM down.
    microvm.preStart = lib.concatMapStrings (
      { image, size, ... }:
      let
        inherit (config.microvm) vmHostPackages;
        path = lib.escapeShellArg image;
      in
      ''
        if [ -e ${path} ]; then
          if [ "$(${vmHostPackages.coreutils}/bin/stat -c %s ${path})" -gt ${toString (size * 1024 * 1024)} ]; then
            echo ${lib.escapeShellArg "warning: ${image} is larger than its configured ${toString size} MiB; shrink it while the VM is stopped"} >&2
          fi
        else
          ${vmHostPackages.coreutils}/bin/rm -f ${path}.new
          ${vmHostPackages.coreutils}/bin/truncate -s ${toString size}M ${path}.new
          ${vmHostPackages.e2fsprogs}/bin/mkfs.ext4 -q ${path}.new
          ${vmHostPackages.coreutils}/bin/mv -T ${path}.new ${path}
        fi
        ${vmHostPackages.util-linux}/bin/fallocate --length ${toString size}MiB ${path} \
          || echo ${lib.escapeShellArg "warning: could not reserve ${toString size} MiB for ${image}; the host disk is overcommitted"} >&2
      ''
    ) config.microvm.volumes;
    # Stable virtio identities also make /nix available during stage 2.
    fileSystems = lib.genAttrs [ "/home" "/var" "/nix" ] (mountPoint: {
      device = lib.mkForce "/dev/disk/by-id/virtio-${cfg.name}-${builtins.baseNameOf mountPoint}";
      neededForBoot = mountPoint == "/nix";
      autoResize = true;
    });
  };
}
