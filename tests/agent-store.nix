{ pkgs }:
let
  oldDependency = pkgs.writeText "old-image-only" "old dependency";
  deployment = pkgs.writeShellScriptBin "guest-deployment" ''
    cat ${oldDependency}
  '';
  disk =
    pkgs.runCommand "agent-store-test.qcow2"
      {
        nativeBuildInputs = [
          pkgs.e2fsprogs
          pkgs.qemu
        ];
      }
      ''
        truncate -s 2G disk.raw
        mkfs.ext4 -m 0 -L agent-store-test disk.raw
        qemu-img convert -f raw -O qcow2 disk.raw "$out"
      '';
  node = image: { lib, ... }: {
    imports = [
      ../modules/agents/vm/store.nix
    ];
    system.stateVersion = "26.05";
    boot.initrd.availableKernelModules = [ "virtio_blk" ];
    fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" ];
    };
    fileSystems."/nix" = {
      device = "/dev/disk/by-id/virtio-agent-store-test";
      fsType = "ext4";
      neededForBoot = true;
    };
    environment.systemPackages = [ pkgs.bash ];
    nix.settings = {
      experimental-features = [ "nix-command" ];
      substituters = [ ];
      trusted-users = [ "root" ];
    };
    virtualisation = {
      memorySize = 2048;
      restrictNetwork = true;
      mountHostNixStore = false;
      useNixStoreImage = true;
      writableStore = false;
      useDefaultFilesystems = false;
      fileSystems = lib.mkForce { };
      diskImage = null;
      additionalPaths = lib.optionals (image == "A") [ deployment ];
      qemu.options = [
        "-drive file=$AGENT_STORE_TEST_DISK,if=none,id=agent-store-test,format=qcow2"
        "-device virtio-blk-pci,drive=agent-store-test,serial=agent-store-test"
      ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "agent-store";
  # Otherwise the driver preloads the A-only deployment into image B as well.
  includeTestScriptReferences = false;
  nodes.image_a = node "A";
  nodes.image_b = node "B";
  testScript = ''
    import os
    import subprocess
    from pathlib import Path

    disk = Path.cwd() / "persistent-agent-store.qcow2"
    subprocess.run(["cp", "${disk}", str(disk)], check=True)
    disk.chmod(0o600)
    os.environ["AGENT_STORE_TEST_DISK"] = str(disk)

    with subtest("A guest deployment survives boot image replacement and GC"):
        image_a.start()
        image_a.wait_for_unit("multi-user.target")
        image_a.succeed("nix-env --profile /nix/var/nix/profiles/guest-deployment --set ${deployment}")
        image_a.shutdown()
        image_b.start()
        image_b.wait_for_unit("multi-user.target")
        image_b.succeed("test ! -e /nix/.ro-store/${builtins.baseNameOf oldDependency}")
        image_b.succeed("nix-store --gc")
        image_b.succeed("nix-store --verify --check-contents")
        image_b.succeed('test "$(/nix/var/nix/profiles/guest-deployment/bin/guest-deployment)" = "old dependency"')

    with subtest("The guest can build offline from its own store"):
        image_b.succeed("nix-build --no-out-link --option substituters \"\" --expr 'derivation { name = \"offline-build\"; system = \"x86_64-linux\"; builder = (builtins.storePath \"${pkgs.bash}\") + \"/bin/bash\"; args = [ \"-c\" \"echo built > $out\" ]; }'")
  '';
}
