# The KubeVirt containerDisk of a klusse runner VM, as one image layer: the kernel and initrd
# for KubeVirt's kernel boot, and the system's store as an erofs disk labelled nix-store. The
# store's top level also holds `.system`, a link to the system that the manifest's
# `init=/nix/.ro-store/.system/init` boots, and `.registration`, which registers the store's
# paths at boot. CI pushes the layer as an image (.github/workflows/klusse-runner-vm.yml).
{
  runCommand,
  closureInfo,
  erofs-utils,
  gnutar,
  toplevel,
  kernel,
  initialRamdisk,
  kernelFile,
  initrdFile,
}:
let
  closure = closureInfo { rootPaths = [ toplevel ]; };
in
runCommand "klusse-runner-container-disk"
  {
    nativeBuildInputs = [
      erofs-utils
      gnutar
    ];
    # The layer holds the store, but nothing outside it refers to these paths.
    __structuredAttrs = true;
    unsafeDiscardReferences.out = true;
    passthru = { inherit toplevel; };
  }
  ''
    mkdir -p store root/boot root/disk
    xargs -a ${closure}/store-paths cp -a --target-directory=store
    ln -s ${toplevel} store/.system
    cp ${closure}/registration store/.registration
    mkfs.erofs -L nix-store -zlz4hc -T0 --all-root root/disk/store.erofs store
    cp ${kernel}/${kernelFile} root/boot/vmlinuz
    cp ${initialRamdisk}/${initrdFile} root/boot/initrd
    chmod 0444 root/boot/* root/disk/*
    mkdir $out
    # KubeVirt's qemu runs as 107.
    tar --sort=name --mtime=@0 --owner=107 --group=107 --numeric-owner -C root -cf $out/layer.tar boot disk
  ''
