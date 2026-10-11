{ pkgs }:
let
  seed = pkgs.callPackage ../modules/agents/vm/store-seed-package.nix { };
  oldDependency = pkgs.writeText "old-image-only" "old dependency";
  deployment = pkgs.writeShellScriptBin "guest-deployment" ''
    cat ${oldDependency}
  '';
  interruptedSeed = pkgs.writeShellApplication {
    name = "interrupted-agent-store-seed";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      cp() {
        ${pkgs.coreutils}/bin/cp "$@"
        if [ ! -e "$persistent/interrupted-once" ]; then
          touch "$persistent/interrupted-once"
          sync -f "$persistent"
          echo agent-store-test-copy-interrupted
          sleep infinity
        fi
      }
    ''
    + builtins.readFile ../modules/agents/vm/store-seed.sh;
  };
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
    environment.etc."boot-image".text = image;
    environment.systemPackages = [
      seed
      pkgs.bash
      pkgs.coreutils
    ];
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
    boot.initrd.systemd.services.agent-store-seed.serviceConfig.ExecStart = lib.mkIf (image == "A") (
      lib.mkForce "${lib.getExe interruptedSeed} /sysroot/nix/.ro-store /sysroot/nix"
    );
    boot.initrd.systemd.storePaths = lib.optional (image == "A") interruptedSeed;
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

    with subtest("Recover an interrupted first-boot copy"):
        image_a.start()
        image_a.wait_for_console_text("agent-store-test-copy-interrupted")
        image_a.crash()
        image_a.start()
        image_a.wait_for_unit("multi-user.target")
        image_a.succeed("test ! -e /nix/.agent-store-seed")

    with subtest("Preserve a guest deployment across boot image replacement"):
        image_a.succeed("mkdir -p /nix/var/nix/profiles/agent-deploy")
        image_a.succeed("nix-env --profile /nix/var/nix/profiles/agent-deploy/current --set ${deployment}")
        image_a.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_a.shutdown()
        image_b.start()
        image_b.wait_for_unit("multi-user.target")
        image_b.succeed("test $(cat /etc/boot-image) = B")
        image_b.succeed("test ! -e /nix/.ro-store/${builtins.baseNameOf oldDependency}")
        image_b.succeed("test ! -d /var/cache/agent-store-test")
        image_b.succeed('test "$(findmnt --first-only --noheadings --mountpoint /nix/store --output FSTYPE)" = ext4')
        image_b.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_b.succeed("nix-store --gc")
        image_b.succeed("nix-store --verify --check-contents")
        image_b.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_b.succeed("nix-build --no-out-link --option substituters \"\" --expr 'derivation { name = \"offline-build\"; system = \"x86_64-linux\"; builder = (builtins.storePath \"${pkgs.bash}\") + \"/bin/bash\"; args = [ \"-c\" \"echo built > $out\" ]; }'")

    with subtest("Disk exhaustion does not publish partial paths"):
        image_b.succeed("mkdir /run/space-seed; dd if=/dev/zero of=/run/space-seed/space-fixture bs=1M count=8")
        image_b.succeed("fallocate -l $(($(df -B1 --output=avail /nix | tail -1) - 65536)) /nix/fill")
        image_b.fail("agent-store-seed /run/space-seed /nix")
        image_b.succeed("test ! -e /nix/.rw-store/store/space-fixture")
        image_b.succeed('test "$(/nix/var/nix/profiles/agent-deploy/current/bin/guest-deployment)" = "old dependency"')
        image_b.succeed("rm /nix/fill; agent-store-seed /run/space-seed /nix")
        image_b.succeed("cmp /run/space-seed/space-fixture /nix/store/space-fixture")
        image_b.succeed("rm /nix/.rw-store/store/space-fixture")

  '';
}
