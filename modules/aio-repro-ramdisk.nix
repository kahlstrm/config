# Temporary: an ext4 RAM disk for reproducing virtio-blk requests that never
# complete under QEMU's aio=io_uring without wearing the SSD. Stopping the
# service, which a switch to a config without this module does, unmounts the
# disk and unloads brd, which frees its RAM.
{ sizeGiB }:
{
  pkgs,
  currentSystemUser,
  ...
}:
let
  mountPoint = "/mnt/aio-ram";
in
{
  systemd.services.aio-repro-ramdisk = {
    description = "ext4 RAM disk for the aio=io_uring stall reproducer";
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.kmod
      pkgs.e2fsprogs
      pkgs.util-linux
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      modprobe brd rd_nr=1 rd_size=${toString (sizeGiB * 1024 * 1024)}
      mkfs.ext4 -q -F /dev/ram0
      mkdir -p ${mountPoint}
      mount /dev/ram0 ${mountPoint}
      chown ${currentSystemUser}: ${mountPoint}
    '';
    preStop = ''
      if mountpoint -q ${mountPoint}; then umount ${mountPoint}; fi
      rmdir ${mountPoint} || true
      rmmod brd
    '';
  };
}
