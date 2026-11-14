# A temporary compute runner in a KubeVirt VM on klusse, which works like an orb
# (infra/docs/adr/2026-11-14-temporary-compute-runners.md): the runner user has passwordless
# root and no approval prompts, and the VM is the boundary.
#
# The VM boots from a containerDisk (`system.build.containerDisk`), which its manifest pins by
# digest, holding the kernel, the initrd and an erofs image of the system's store. The claim,
# the virtio disk `persistent`, is formatted on first boot and holds /nix, with /home, /var and
# /tmp beneath it; each boot seeds the image's closure into its store (../agents/vm/store.nix),
# so builds survive restarts and a new image. The Amp access key arrives as the Secret disk `amp-runner-token`.
#
# The cluster's NetworkPolicy is the boundary: public HTTP and HTTPS, and DNS to two public
# resolvers, nothing private. The guest's own firewall allows the same, but the runner's root
# can lift it. Before the runner starts, on every boot, `runner-isolation-check` must reach the
# internet and must not reach any private target, bypassing the guest firewall so it tests the
# cluster's policy; otherwise the runner stays down.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.klusseRunner;
  persistent = "/nix/persist";
  token = "/run/keys/amp-runner";
  checkUser = "isolation-check";
  # What only the cluster's policy keeps out: anything private, local or multicast.
  privateRanges = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/3"
  ];
  check = pkgs.writeShellApplication {
    name = "runner-isolation-check";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
    text = builtins.readFile ./isolation-check.sh;
  };
in
{
  imports = [ ../agents/vm/store.nix ];

  options.local.klusseRunner = {
    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1"
        "9.9.9.9"
      ];
      description = "Public DNS resolvers the guest uses; the VM's NetworkPolicy allows these.";
    };
    mustReach = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "1.1.1.1:443"
        "9.9.9.9:443"
      ];
      description = "host:port targets the isolation check must reach, so a timeout below means a policy and not a missing network.";
    };
    mustNotReach = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "host:port targets, with /udp for a UDP probe, the isolation check must not reach: each must time out.";
      default = [
        # The nodes' Talos API and kubelet, this VM's own node among them, and the Kubernetes API.
        "10.10.10.11:50000"
        "10.10.10.12:50000"
        "10.10.10.13:50000"
        "10.10.10.21:50000"
        "10.10.10.22:50000"
        "10.10.10.21:10250"
        "10.10.10.22:10250"
        "10.10.10.10:6443"
        "10.10.10.11:6443"
        # The workers' pod gateways, which are also the nodes.
        "10.244.1.1:10250"
        "10.244.5.1:10250"
        # Services and the pods behind them: the API, cluster DNS and the ingress address.
        "10.96.0.1:443"
        "10.96.0.10:53"
        "10.96.0.10:53/udp"
        "10.10.10.80:443"
        # Both routers and pannu.
        "10.10.10.1:443"
        "10.1.1.1:443"
        "10.1.1.10:22"
        "169.254.169.254:80"
      ];
    };
  };

  config = {
    system.stateVersion = "26.05";

    boot.loader.grub.enable = false;
    boot.initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
      "iso9660"
    ];
    # KubeVirt boots the kernel directly with the command line in the VM's manifest:
    # console=ttyS0 init=/nix/.ro-store/.system/init (./container-disk.nix).

    fileSystems = {
      "/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "mode=0755"
          "size=2G"
        ];
      };
      "/nix" = {
        device = "/dev/disk/by-id/virtio-persistent";
        fsType = "ext4";
        autoFormat = true;
        autoResize = true;
        neededForBoot = true;
      };
    }
    // lib.genAttrs [ "/home" "/var" "/tmp" ] (path: {
      device = "${persistent}${path}";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/nix" ];
      neededForBoot = true;
    })
    // {
      ${token} = {
        device = "/dev/disk/by-id/virtio-amp-runner-token";
        fsType = "iso9660";
        options = [
          "ro"
          "nofail"
        ];
      };
    };
    # The bind mounts' sources on a freshly formatted claim.
    boot.initrd.systemd.services.persistent-directories = {
      description = "Create the persistent directories";
      unitConfig.DefaultDependencies = false;
      requires = [ "sysroot-nix.mount" ];
      after = [ "sysroot-nix.mount" ];
      before = [
        "sysroot-home.mount"
        "sysroot-var.mount"
        "sysroot-tmp.mount"
      ];
      requiredBy = [
        "sysroot-home.mount"
        "sysroot-var.mount"
        "sysroot-tmp.mount"
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /sysroot${persistent}/home /sysroot${persistent}/var
        mkdir -p -m 1777 /sysroot${persistent}/tmp
      '';
    };
    boot.tmp.cleanOnBoot = true;
    # The image's store paths are registered in the persistent store's database at each boot.
    boot.postBootCommands = ''
      if [ -e /nix/.ro-store/.registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix/.ro-store/.registration
      fi
    '';

    networking = {
      useNetworkd = true;
      useDHCP = false;
      enableIPv6 = false;
      nameservers = cfg.resolvers;
      nftables.enable = true;
      # The check's user exists only on the running system.
      nftables.preCheckRuleset = "sed 's/skuid \"${checkUser}\"/skuid root/' -i ruleset.conf";
      # Nothing listens; the firewall drops every new inbound connection.
      firewall = {
        enable = true;
        allowPing = false;
      };
      nftables.tables.runner-egress = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy drop;
            oifname "lo" accept
            ct state established,related accept
            meta skuid "${checkUser}" accept
            ip daddr { ${lib.concatStringsSep ", " cfg.resolvers} } meta l4proto { tcp, udp } th dport 53 accept
            udp dport 67 accept
            ip daddr != { ${lib.concatStringsSep ", " privateRanges} } tcp dport { 80, 443 } accept
            meta l4proto tcp reject with tcp reset
            reject
          }
        '';
      };
    };
    # KubeVirt's masquerade binding serves the address over DHCP inside the VM's pod.
    systemd.network.networks."10-pod" = {
      matchConfig.Type = "ether";
      networkConfig.DHCP = "ipv4";
      dhcpV4Config = {
        UseDNS = false;
        UseNTP = false;
      };
    };
    # No route to NTP; KubeVirt's kvm-clock follows the node's clock.
    services.timesyncd.enable = false;
    services.qemuGuest.enable = true;

    users.users.${checkUser} = {
      isSystemUser = true;
      group = checkUser;
    };
    users.groups.${checkUser} = { };
    systemd.services.runner-isolation-check = {
      description = "Check that this VM reaches the internet and nothing private";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = checkUser;
        Group = checkUser;
        ExecStart = "${lib.getExe check} ${
          lib.escapeShellArgs (map (target: "+${target}") cfg.mustReach ++ cfg.mustNotReach)
        }";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };
    systemd.services.amp-runner = {
      requires = [ "runner-isolation-check.service" ];
      after = [ "runner-isolation-check.service" ];
      unitConfig.RequiresMountsFor = [ token ];
    };

    local.ampRunner = {
      enable = true;
      hostDeploy = false;
      sudo = true;
      home = "/home/amp";
      workspace = "/home/amp/workspace";
      repositories = [ "https://github.com/kahlstrm/config" ];
      tokenFile = "${token}/key";
      extraPermissions = [
        {
          tool = "*";
          action = "allow";
        }
      ];
    };

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      extra-substituters = [ "https://nix-community.cachix.org" ];
      extra-trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      # Builds run on the claim, not in the memory-backed root.
      build-dir = "/nix/var/nix/builds";
      # Collect garbage while building when the claim runs low.
      min-free = 10 * 1024 * 1024 * 1024;
      max-free = 30 * 1024 * 1024 * 1024;
    };
    programs.nix-ld.enable = true;
    environment.systemPackages = [
      pkgs.git
      pkgs.gh
      pkgs.curl
      pkgs.jq
    ];
    documentation.enable = false;

    system.build.containerDisk = pkgs.callPackage ./container-disk.nix {
      inherit (config.system.build) toplevel kernel initialRamdisk;
      kernelFile = config.system.boot.loader.kernelFile;
      initrdFile = config.system.boot.loader.initrdFile;
    };
  };
}
