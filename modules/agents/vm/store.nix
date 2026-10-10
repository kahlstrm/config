{
  config,
  lib,
  pkgs,
  ...
}:
let
  seed = pkgs.callPackage ./store-seed-package.nix { };
in
{
  boot.initrd.systemd.enable = true;
  boot.initrd.systemd.storePaths = [ seed ];
  boot.initrd.systemd.services.agent-store-seed = {
    description = "Preserve the boot image closure in the guest Nix store";
    unitConfig.DefaultDependencies = false;
    requires = [
      "sysroot-nix.mount"
      "sysroot-nix-.ro\\x2dstore.mount"
    ];
    after = [
      "sysroot-nix.mount"
      "sysroot-nix-.ro\\x2dstore.mount"
    ];
    before = [ "sysroot-nix-store.mount" ];
    requiredBy = [ "sysroot-nix-store.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "15min";
      ExecStart = "${lib.getExe seed} /sysroot/nix/.ro-store /sysroot/nix";
    };
  };
  # Keep the existing upper-store location so deployments need no data migration.
  fileSystems."/nix/.ro-store" = {
    device =
      if (config.microvm.storeDiskType or "erofs") == "erofs" then
        "/dev/disk/by-label/nix-store"
      else
        "/dev/vda";
    fsType = config.microvm.storeDiskType or "erofs";
    options = [ "ro" ];
    neededForBoot = true;
    noCheck = true;
  };
  fileSystems."/nix/store" = lib.mkForce {
    device = "/nix/.rw-store/store";
    fsType = "none";
    options = [ "bind" ];
    neededForBoot = true;
    depends = [ "/nix" ];
  };
  systemd.services.nix-daemon.enable = true;
  systemd.sockets.nix-daemon.enable = true;
}
